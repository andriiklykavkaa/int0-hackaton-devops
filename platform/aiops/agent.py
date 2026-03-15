#!/usr/bin/env python3
"""Minimal AIOps agent for cluster and Prometheus health analysis."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

PROMPTS_DIR = Path(__file__).resolve().parent / "prompts"

PROMETHEUS_QUERIES = {
    "request_rate": "sum(retail:http_request_rate5m)",
    "error_rate": "retail:http_error_rate5m",
    "latency_p95": "retail:http_latency_p95_seconds5m",
    "pod_restarts": (
        'sum by (pod) (increase(kube_pod_container_status_restarts_total'
        '{namespace="__NAMESPACE__"}[15m]))'
    ),
    "cpu_throttling": (
        'sum by (pod) (rate(container_cpu_cfs_throttled_periods_total'
        '{namespace="__NAMESPACE__",container!=""}[5m])) / clamp_min(sum by (pod) '
        '(rate(container_cpu_cfs_periods_total{namespace="__NAMESPACE__",container!=""}[5m])), 0.001)'
    ),
    "target_down": 'min by (job) (up{namespace="__NAMESPACE__"})',
    "queue_backlog": 'sum(rabbitmq_queue_messages_ready{namespace="__NAMESPACE__"})',
}


@dataclass
class Finding:
    severity: str
    source: str
    title: str
    details: str
    recommendation: str


@dataclass
class LlmConfig:
    base_url: str
    model: str
    api_key: str
    max_tokens: int | None = None


@dataclass
class CollectorError:
    source: str
    collector: str
    details: str
    query: str | None = None


LOG_PATTERNS = [
    (
        "critical",
        "runtime_exception",
        ("exception", "traceback", "panic:", "fatal"),
        "Application error signature found in pod logs.",
        "Inspect the stack trace, recent deploys, and dependency failures for this pod.",
    ),
    (
        "warning",
        "dependency_failure",
        ("connection refused", "timed out", "timeout", "connection reset"),
        "Connectivity or dependency failure found in pod logs.",
        "Check upstream dependencies, DNS/service discovery, and network policies.",
    ),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect cluster health signals and produce a compact incident summary."
    )
    parser.add_argument("--environment", default="stage")
    parser.add_argument("--namespace", default="retail-store-stage")
    parser.add_argument("--prometheus-url", help="Base URL of Prometheus, e.g. http://localhost:9090")
    parser.add_argument(
        "--mock-dir",
        help="Read collector inputs from a local directory instead of calling kubectl/Prometheus.",
    )
    parser.add_argument("--output", help="Write the full report JSON to this file.")
    parser.add_argument(
        "--enable-llm-analysis",
        action="store_true",
        help="Call an OpenAI-compatible API to generate a higher-level incident diagnosis.",
    )
    parser.add_argument(
        "--llm-base-url",
        default=os.getenv("AIOPS_OPENAI_BASE_URL", ""),
        help="OpenAI-compatible API base URL. Can also come from AIOPS_OPENAI_BASE_URL.",
    )
    parser.add_argument(
        "--llm-model",
        default=os.getenv("AIOPS_OPENAI_MODEL", ""),
        help="Model name for the OpenAI-compatible API. Can also come from AIOPS_OPENAI_MODEL.",
    )
    parser.add_argument(
        "--llm-api-key",
        default=os.getenv("AIOPS_OPENAI_API_KEY", ""),
        help="API key for the OpenAI-compatible API. Can also come from AIOPS_OPENAI_API_KEY.",
    )
    parser.add_argument(
        "--llm-max-tokens",
        type=int,
        default=int(os.getenv("AIOPS_OPENAI_MAX_TOKENS", "0") or "0"),
        help="Optional max_tokens value for the OpenAI-compatible API call.",
    )
    parser.add_argument(
        "--format",
        choices=("markdown", "json"),
        default="markdown",
        help="Console output format.",
    )
    parser.add_argument(
        "--fail-on-collector-errors",
        action="store_true",
        help="Exit non-zero when Kubernetes or Prometheus signal collection fails.",
    )
    parser.add_argument(
        "--log-tail",
        type=int,
        default=200,
        help="Number of log lines to collect for suspicious pods. Default: 200.",
    )
    return parser.parse_args()


def load_mock_json(mock_dir: Path | None, name: str) -> Any | None:
    if not mock_dir:
        return None
    path = mock_dir / f"{name}.json"
    if not path.exists():
        return None
    return json.loads(path.read_text())


def load_mock_text(mock_dir: Path | None, name: str) -> str | None:
    if not mock_dir:
        return None
    path = mock_dir / f"{name}.txt"
    if not path.exists():
        return None
    return path.read_text()


def run_kubectl_json(namespace: str, args: list[str]) -> dict[str, Any]:
    cmd = ["kubectl", "-n", namespace, *args, "-o", "json"]
    completed = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or f"kubectl failed: {' '.join(cmd)}")
    return json.loads(completed.stdout)


def run_kubectl_text(namespace: str, args: list[str]) -> str:
    cmd = ["kubectl", "-n", namespace, *args]
    completed = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or f"kubectl failed: {' '.join(cmd)}")
    return completed.stdout.strip()


def collect_kubernetes(namespace: str, mock_dir: Path | None) -> dict[str, Any]:
    collected: dict[str, Any] = {}
    resources = {
        "pods": ["get", "pods"],
        "deployments": ["get", "deployments"],
        "hpa": ["get", "hpa"],
        "events": ["get", "events", "--field-selector", "type=Warning"],
    }

    for name, cmd in resources.items():
        mock_payload = load_mock_json(mock_dir, name)
        if mock_payload is not None:
            collected[name] = mock_payload
            continue
        try:
            collected[name] = run_kubectl_json(namespace, cmd)
        except Exception as exc:  # pragma: no cover - exercised via runtime
            collected[name] = {"error": str(exc), "items": []}
    return collected


def query_prometheus(base_url: str, query: str) -> dict[str, Any]:
    params = urllib.parse.urlencode({"query": query})
    url = f"{base_url.rstrip('/')}/api/v1/query?{params}"
    with urllib.request.urlopen(url, timeout=10) as response:
        return json.loads(response.read().decode("utf-8"))


def collect_prometheus(namespace: str, base_url: str | None, mock_dir: Path | None) -> dict[str, Any]:
    mock_payload = load_mock_json(mock_dir, "prometheus")
    if mock_payload is not None:
        return mock_payload

    results: dict[str, Any] = {}
    if not base_url:
        return results

    for name, template in PROMETHEUS_QUERIES.items():
        query = template.replace("__NAMESPACE__", namespace)
        try:
            results[name] = query_prometheus(base_url, query)
        except Exception as exc:  # pragma: no cover - exercised via runtime
            results[name] = {"status": "error", "error": str(exc), "query": query}
    return results


def compact_error_message(message: str) -> str:
    lines = [line.strip() for line in message.splitlines() if line.strip()]
    if not lines:
        return "Unknown collector error."
    return lines[-1]


def needs_previous_logs(pod: dict[str, Any]) -> bool:
    for status in pod.get("status", {}).get("containerStatuses", []):
        state = status.get("state", {})
        waiting = state.get("waiting", {})
        if waiting.get("reason") == "CrashLoopBackOff":
            return True
        if status.get("restartCount", 0) > 0:
            return True
    return False


def detect_suspicious_pods(pods: dict[str, Any], prometheus: dict[str, Any]) -> dict[str, bool]:
    suspicious: dict[str, bool] = {}

    for pod in pods.get("items", []):
        name = pod.get("metadata", {}).get("name")
        if not name:
            continue
        phase = pod.get("status", {}).get("phase", "Unknown")
        container_statuses = pod.get("status", {}).get("containerStatuses", [])
        has_waiting_container = any(status.get("state", {}).get("waiting") for status in container_statuses)
        has_unready_container = any(not status.get("ready", True) for status in container_statuses)
        has_restarts = any(status.get("restartCount", 0) > 0 for status in container_statuses)

        if phase != "Running" or has_waiting_container or has_unready_container or has_restarts:
            suspicious[name] = needs_previous_logs(pod)

    for result in prometheus.get("pod_restarts", {}).get("data", {}).get("result", []):
        value = float_value(result)
        if value is not None and value > 2:
            pod_name = result.get("metric", {}).get("pod")
            if pod_name:
                suspicious[pod_name] = True

    return suspicious


def load_mock_logs(mock_dir: Path | None) -> dict[str, Any]:
    payload = load_mock_json(mock_dir, "logs")
    if isinstance(payload, dict):
        return payload
    return {}


def should_ignore_previous_logs_error(message: str) -> bool:
    lowered = message.lower()
    return (
        "previous terminated container" in lowered
        or "not found" in lowered
        or should_ignore_current_logs_error(message)
        or "previous terminated container" in compact_error_message(message).lower()
    )


def should_ignore_current_logs_error(message: str) -> bool:
    lowered = message.lower()
    return (
        "containercreating" in lowered
        or "pod initializing" in lowered
        or "container is waiting to start" in lowered
        or "trying and failing to pull image" in lowered
        or "imagepullbackoff" in lowered
        or "errimagepull" in lowered
    )


def collect_pod_logs(
    namespace: str,
    suspicious_pods: dict[str, bool],
    mock_dir: Path | None,
    log_tail: int,
) -> tuple[dict[str, Any], list[CollectorError]]:
    mock_logs = load_mock_logs(mock_dir)
    collected: dict[str, Any] = {}
    collector_errors: list[CollectorError] = []

    for pod_name, include_previous in suspicious_pods.items():
        if pod_name in mock_logs:
            collected[pod_name] = mock_logs[pod_name]
            continue

        pod_logs: dict[str, str] = {}
        try:
            pod_logs["current"] = run_kubectl_text(
                namespace,
                ["logs", pod_name, "--all-containers=true", f"--tail={log_tail}"],
            )
        except Exception as exc:  # pragma: no cover - exercised via runtime
            if not should_ignore_current_logs_error(str(exc)):
                collector_errors.append(
                    CollectorError(
                        source="kubernetes",
                        collector=f"logs/{pod_name}",
                        details=compact_error_message(str(exc)),
                    )
                )

        if include_previous:
            try:
                previous_logs = run_kubectl_text(
                    namespace,
                    ["logs", pod_name, "--all-containers=true", "--previous", f"--tail={log_tail}"],
                )
                if previous_logs:
                    pod_logs["previous"] = previous_logs
            except Exception as exc:  # pragma: no cover - exercised via runtime
                if not should_ignore_previous_logs_error(str(exc)):
                    collector_errors.append(
                        CollectorError(
                            source="kubernetes",
                            collector=f"logs/{pod_name}/previous",
                            details=compact_error_message(str(exc)),
                        )
                    )

        if pod_logs:
            collected[pod_name] = pod_logs

    return collected, collector_errors


def excerpt_log(text: str, max_lines: int = 20, max_chars: int = 1600) -> str:
    lines = text.splitlines()
    excerpt = "\n".join(lines[-max_lines:])
    if len(excerpt) <= max_chars:
        return excerpt
    return excerpt[-max_chars:]


def build_log_context(pod_logs: dict[str, Any]) -> list[dict[str, str]]:
    context: list[dict[str, str]] = []
    for pod_name, payload in pod_logs.items():
        entry = {"pod": pod_name}
        current = payload.get("current")
        previous = payload.get("previous")
        if current:
            entry["current_excerpt"] = excerpt_log(current)
        if previous:
            entry["previous_excerpt"] = excerpt_log(previous)
        context.append(entry)
    return context


def find_log_match(text: str, patterns: tuple[str, ...]) -> str | None:
    for line in text.splitlines():
        lowered = line.lower()
        if any(pattern in lowered for pattern in patterns):
            return line.strip()
    return None


def collect_collector_errors(
    kubernetes: dict[str, Any],
    prometheus: dict[str, Any],
) -> list[CollectorError]:
    collector_errors: list[CollectorError] = []

    for collector, payload in kubernetes.items():
        error = payload.get("error")
        if error:
            collector_errors.append(
                CollectorError(
                    source="kubernetes",
                    collector=collector,
                    details=compact_error_message(error),
                )
            )

    for collector, payload in prometheus.items():
        error = payload.get("error")
        if error or payload.get("status") == "error":
            collector_errors.append(
                CollectorError(
                    source="prometheus",
                    collector=collector,
                    details=compact_error_message(error or "Prometheus query failed."),
                    query=payload.get("query"),
                )
            )

    return collector_errors


def float_value(result: dict[str, Any]) -> float | None:
    try:
        return float(result["value"][1])
    except Exception:
        return None


def analyze_pods(pods: dict[str, Any]) -> list[Finding]:
    findings: list[Finding] = []
    for pod in pods.get("items", []):
        name = pod.get("metadata", {}).get("name", "unknown")
        phase = pod.get("status", {}).get("phase", "Unknown")
        container_statuses = pod.get("status", {}).get("containerStatuses", [])

        if phase != "Running":
            findings.append(
                Finding(
                    severity="critical",
                    source="kubernetes",
                    title=f"Pod {name} is not running",
                    details=f"Current phase is {phase}.",
                    recommendation=f"Inspect `kubectl describe pod {name}` and recent logs.",
                )
            )

        for status in container_statuses:
            state = status.get("state", {})
            waiting = state.get("waiting", {})
            if waiting:
                reason = waiting.get("reason", "Unknown")
                findings.append(
                    Finding(
                        severity="critical" if reason == "CrashLoopBackOff" else "warning",
                        source="kubernetes",
                        title=f"Container issue in {name}",
                        details=f"{status.get('name', 'container')} is waiting: {reason}.",
                        recommendation="Check container logs and probe configuration.",
                    )
                )
    return findings


def analyze_deployments(deployments: dict[str, Any]) -> list[Finding]:
    findings: list[Finding] = []
    for deployment in deployments.get("items", []):
        name = deployment.get("metadata", {}).get("name", "unknown")
        spec = deployment.get("spec", {})
        status = deployment.get("status", {})
        desired = spec.get("replicas", 1)
        available = status.get("availableReplicas", 0)
        updated = status.get("updatedReplicas", 0)
        if available < desired or updated < desired:
            findings.append(
                Finding(
                    severity="warning",
                    source="kubernetes",
                    title=f"Deployment {name} is not fully available",
                    details=f"desired={desired}, updated={updated}, available={available}",
                    recommendation=f"Inspect rollout status for deployment/{name}.",
                )
            )
    return findings


def analyze_hpa(hpas: dict[str, Any]) -> list[Finding]:
    findings: list[Finding] = []
    for hpa in hpas.get("items", []):
        name = hpa.get("metadata", {}).get("name", "unknown")
        spec = hpa.get("spec", {})
        status = hpa.get("status", {})
        current = status.get("currentReplicas", 0)
        maximum = spec.get("maxReplicas")

        for condition in status.get("conditions", []):
            if condition.get("type") == "ScalingLimited" and condition.get("status") == "True":
                findings.append(
                    Finding(
                        severity="warning",
                        source="kubernetes",
                        title=f"HPA {name} is scaling-limited",
                        details=condition.get("message", "Autoscaler hit a scaling limit."),
                        recommendation="Increase max replicas or reduce incoming load.",
                    )
                )

        if maximum is not None and current >= maximum:
            findings.append(
                Finding(
                    severity="warning",
                    source="kubernetes",
                    title=f"HPA {name} is at max replicas",
                    details=f"current={current}, max={maximum}",
                    recommendation="Review capacity and scaling thresholds for this service.",
                )
            )
    return findings


def analyze_events(events: dict[str, Any]) -> list[Finding]:
    findings: list[Finding] = []
    items = sorted(
        events.get("items", []),
        key=lambda item: item.get("lastTimestamp") or item.get("eventTime") or "",
        reverse=True,
    )
    for event in items[:5]:
        obj = event.get("involvedObject", {})
        findings.append(
            Finding(
                severity="warning",
                source="event",
                title=f"{event.get('reason', 'Warning')} on {obj.get('kind', 'Object')} {obj.get('name', '')}",
                details=event.get("message", "No event message"),
                recommendation="Inspect the affected resource and correlate with metrics.",
            )
        )
    return findings


def analyze_prometheus(metrics: dict[str, Any]) -> list[Finding]:
    findings: list[Finding] = []

    for result in metrics.get("error_rate", {}).get("data", {}).get("result", []):
        value = float_value(result)
        if value is not None and value > 0.01:
            app = result.get("metric", {}).get("application", "unknown")
            findings.append(
                Finding(
                    severity="critical",
                    source="prometheus",
                    title=f"High 5xx error rate on {app}",
                    details=f"error_rate={value:.2%}",
                    recommendation=f"Inspect {app} logs, recent deploys, and upstream dependencies.",
                )
            )

    for result in metrics.get("latency_p95", {}).get("data", {}).get("result", []):
        value = float_value(result)
        if value is not None and value > 0.5:
            app = result.get("metric", {}).get("application", "unknown")
            findings.append(
                Finding(
                    severity="warning",
                    source="prometheus",
                    title=f"High p95 latency on {app}",
                    details=f"p95={value:.3f}s",
                    recommendation=f"Check saturation, dependency latency, and scaling for {app}.",
                )
            )

    for result in metrics.get("pod_restarts", {}).get("data", {}).get("result", []):
        value = float_value(result)
        if value is not None and value > 2:
            pod = result.get("metric", {}).get("pod", "unknown")
            findings.append(
                Finding(
                    severity="warning",
                    source="prometheus",
                    title=f"Pod {pod} is restarting",
                    details=f"restarts_15m={value:.0f}",
                    recommendation=f"Inspect `kubectl logs {pod}` and probe failures.",
                )
            )

    for result in metrics.get("cpu_throttling", {}).get("data", {}).get("result", []):
        value = float_value(result)
        if value is not None and value > 0.2:
            pod = result.get("metric", {}).get("pod", "unknown")
            findings.append(
                Finding(
                    severity="warning",
                    source="prometheus",
                    title=f"High CPU throttling on {pod}",
                    details=f"throttling_ratio={value:.2%}",
                    recommendation="Increase CPU requests/limits or reduce load on the pod.",
                )
            )

    for result in metrics.get("target_down", {}).get("data", {}).get("result", []):
        value = float_value(result)
        if value == 0:
            job = result.get("metric", {}).get("job", "unknown")
            findings.append(
                Finding(
                    severity="critical",
                    source="prometheus",
                    title=f"Prometheus target down for {job}",
                    details="Prometheus cannot scrape this target.",
                    recommendation="Verify pod health, ServiceMonitor selection, and endpoint path/port.",
                )
            )

    for result in metrics.get("queue_backlog", {}).get("data", {}).get("result", []):
        value = float_value(result)
        if value is not None and value > 100:
            findings.append(
                Finding(
                    severity="warning",
                    source="prometheus",
                    title="RabbitMQ backlog is growing",
                    details=f"ready_messages={value:.0f}",
                    recommendation="Check consumer health and orders throughput.",
                )
            )

    return findings


def analyze_logs(pod_logs: dict[str, Any]) -> list[Finding]:
    findings: list[Finding] = []

    for pod_name, payload in pod_logs.items():
        combined = "\n".join(
            [
                payload.get("current", ""),
                payload.get("previous", ""),
            ]
        ).strip()
        if not combined:
            continue

        for severity, label, patterns, details, recommendation in LOG_PATTERNS:
            matched_line = find_log_match(combined, patterns)
            if not matched_line:
                continue
            findings.append(
                Finding(
                    severity=severity,
                    source="logs",
                    title=f"Log signal in {pod_name}: {label.replace('_', ' ')}",
                    details=f"{details} Matched line: {matched_line}",
                    recommendation=recommendation,
                )
            )

    return findings


def summarize(
    findings: list[Finding],
    collector_errors: list[CollectorError],
    total_collectors: int,
    pod_logs: dict[str, Any],
) -> dict[str, Any]:
    severity_rank = {"info": 0, "warning": 1, "critical": 2}
    overall = "healthy"
    collection_status = "complete"

    if collector_errors:
        collection_status = "failed" if len(collector_errors) >= total_collectors else "partial_failure"

    if collector_errors and findings:
        overall = "degraded"
    elif collector_errors:
        overall = "unknown"
    elif findings:
        overall = max(findings, key=lambda item: severity_rank[item.severity]).severity

    return {
        "overall_status": overall,
        "collection_status": collection_status,
        "finding_count": len(findings),
        "critical_count": sum(1 for item in findings if item.severity == "critical"),
        "warning_count": sum(1 for item in findings if item.severity == "warning"),
        "collector_error_count": len(collector_errors),
        "pod_log_count": len(pod_logs),
        "collector_errors": [asdict(item) for item in collector_errors],
        "findings": [asdict(item) for item in findings],
    }


def load_prompt(name: str) -> str:
    return (PROMPTS_DIR / name).read_text()


def build_llm_config(args: argparse.Namespace, mock_dir: Path | None) -> LlmConfig | None:
    if not args.enable_llm_analysis:
        return None
    if load_mock_text(mock_dir, "llm_response") is not None:
        return None
    if not args.llm_base_url or not args.llm_model or not args.llm_api_key:
        raise RuntimeError(
            "LLM analysis requires --llm-base-url, --llm-model, and --llm-api-key "
            "(or matching AIOPS_OPENAI_* environment variables)."
        )
    return LlmConfig(
        base_url=args.llm_base_url,
        model=args.llm_model,
        api_key=args.llm_api_key,
        max_tokens=args.llm_max_tokens or None,
    )


def call_openai_compatible(config: LlmConfig, system_prompt: str, user_prompt: str) -> str:
    url = f"{config.base_url.rstrip('/')}/chat/completions"
    payload = {
        "model": config.model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0.2,
    }
    if config.max_tokens is not None:
        payload["max_tokens"] = config.max_tokens
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {config.api_key}",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.loads(response.read().decode("utf-8"))
    return body["choices"][0]["message"]["content"].strip()


def generate_llm_analysis(
    environment: str,
    namespace: str,
    summary: dict[str, Any],
    pod_logs: dict[str, Any],
    mock_dir: Path | None,
    config: LlmConfig | None,
) -> str | None:
    mock_text = load_mock_text(mock_dir, "llm_response")
    if mock_text is not None:
        return mock_text.strip()

    if not config:
        return None

    system_prompt = load_prompt("incident-analysis-system.txt")
    user_prompt = json.dumps(
        {
            "environment": environment,
            "namespace": namespace,
            "overall_status": summary["overall_status"],
            "critical_count": summary["critical_count"],
            "warning_count": summary["warning_count"],
            "findings": summary["findings"],
            "pod_logs": build_log_context(pod_logs),
        },
        indent=2,
    )
    return call_openai_compatible(config, system_prompt, user_prompt)


def render_markdown(
    environment: str,
    namespace: str,
    summary: dict[str, Any],
    pod_logs: dict[str, Any],
    llm_analysis: str | None,
) -> str:
    lines = [
        f"# AIOps Incident Summary",
        "",
        f"- Environment: `{environment}`",
        f"- Namespace: `{namespace}`",
        f"- Overall status: `{summary['overall_status']}`",
        f"- Collection status: `{summary['collection_status']}`",
        f"- Findings: `{summary['finding_count']}`",
        f"- Critical: `{summary['critical_count']}`",
        f"- Warning: `{summary['warning_count']}`",
        f"- Pod logs collected: `{summary['pod_log_count']}`",
        f"- Collector errors: `{summary['collector_error_count']}`",
        "",
    ]

    if summary["collector_errors"]:
        lines.extend(
            [
                "Signal collection completed with errors. Findings may be incomplete until Kubernetes and Prometheus access is restored.",
                "",
                "## Collector Errors",
                "",
            ]
        )
        for item in summary["collector_errors"]:
            lines.append(f"- [{item['source']}/{item['collector']}] {item['details']}")
            if item.get("query"):
                lines.append(f"  - Query: `{item['query']}`")
        lines.append("")

    if not summary["findings"]:
        if summary["collector_errors"]:
            lines.append("No workload findings were produced because signal collection was incomplete.")
        else:
            lines.append("No urgent findings detected from the current Kubernetes and Prometheus signals.")
        return "\n".join(lines)

    lines.append("## Findings")
    lines.append("")
    for item in summary["findings"]:
        lines.extend(
            [
                f"- [{item['severity']}] {item['title']}",
                f"  - Details: {item['details']}",
                f"  - Action: {item['recommendation']}",
            ]
        )

    if pod_logs:
        lines.extend(["", "## Log Evidence", ""])
        for pod_name, payload in pod_logs.items():
            lines.append(f"- Pod `{pod_name}`")
            if payload.get("current"):
                lines.append("  - Current excerpt:")
                for line in excerpt_log(payload["current"], max_lines=12, max_chars=800).splitlines():
                    lines.append(f"    {line}")
            if payload.get("previous"):
                lines.append("  - Previous excerpt:")
                for line in excerpt_log(payload["previous"], max_lines=12, max_chars=800).splitlines():
                    lines.append(f"    {line}")

    if llm_analysis:
        lines.extend(["", "## AI Diagnosis", "", llm_analysis])

    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    mock_dir = Path(args.mock_dir).resolve() if args.mock_dir else None
    llm_config = build_llm_config(args, mock_dir)

    kubernetes = collect_kubernetes(args.namespace, mock_dir)
    prometheus = collect_prometheus(args.namespace, args.prometheus_url, mock_dir)
    suspicious_pods = detect_suspicious_pods(kubernetes.get("pods", {}), prometheus)
    pod_logs, log_errors = collect_pod_logs(args.namespace, suspicious_pods, mock_dir, args.log_tail)
    collector_errors = collect_collector_errors(kubernetes, prometheus)
    collector_errors.extend(log_errors)
    total_collectors = len(kubernetes) + len(prometheus) + len(suspicious_pods)

    findings = []
    findings.extend(analyze_pods(kubernetes.get("pods", {})))
    findings.extend(analyze_deployments(kubernetes.get("deployments", {})))
    findings.extend(analyze_hpa(kubernetes.get("hpa", {})))
    findings.extend(analyze_events(kubernetes.get("events", {})))
    findings.extend(analyze_prometheus(prometheus))
    findings.extend(analyze_logs(pod_logs))

    report = {
        "environment": args.environment,
        "namespace": args.namespace,
        "summary": summarize(findings, collector_errors, total_collectors, pod_logs),
        "raw": {
            "kubernetes": kubernetes,
            "prometheus": prometheus,
            "logs": pod_logs,
        },
    }

    llm_analysis = generate_llm_analysis(
        environment=args.environment,
        namespace=args.namespace,
        summary=report["summary"],
        pod_logs=pod_logs,
        mock_dir=mock_dir,
        config=llm_config,
    )
    report["llm_analysis"] = llm_analysis

    if args.output:
        output_path = Path(args.output)
        output_path.write_text(json.dumps(report, indent=2))

    if args.format == "json":
        print(json.dumps(report, indent=2))
    else:
        print(
            render_markdown(
                args.environment,
                args.namespace,
                report["summary"],
                pod_logs,
                llm_analysis,
            )
        )

    if args.fail_on_collector_errors and collector_errors:
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
