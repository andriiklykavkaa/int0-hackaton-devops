import contextlib
import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parent
AGENT_PATH = REPO_ROOT / "platform" / "aiops" / "agent.py"


def load_agent_module():
    spec = importlib.util.spec_from_file_location("aiops_agent", AGENT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class AIOpsAgentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.agent = load_agent_module()

    def test_healthy_summary_when_collection_is_complete_and_no_findings(self):
        kubernetes = {
            "pods": {
                "items": [
                    {
                        "metadata": {"name": "catalog-stage-123"},
                        "status": {
                            "phase": "Running",
                            "containerStatuses": [
                                {
                                    "name": "catalog",
                                    "state": {"running": {}},
                                }
                            ],
                        },
                    }
                ]
            },
            "deployments": {
                "items": [
                    {
                        "metadata": {"name": "catalog-stage"},
                        "spec": {"replicas": 1},
                        "status": {"updatedReplicas": 1, "availableReplicas": 1},
                    }
                ]
            },
            "hpa": {"items": []},
            "events": {"items": []},
        }
        prometheus = {
            name: {"status": "success", "data": {"result": []}}
            for name in self.agent.PROMETHEUS_QUERIES
        }

        collector_errors = self.agent.collect_collector_errors(kubernetes, prometheus)
        findings = []
        findings.extend(self.agent.analyze_pods(kubernetes["pods"]))
        findings.extend(self.agent.analyze_deployments(kubernetes["deployments"]))
        findings.extend(self.agent.analyze_hpa(kubernetes["hpa"]))
        findings.extend(self.agent.analyze_events(kubernetes["events"]))
        findings.extend(self.agent.analyze_prometheus(prometheus))

        summary = self.agent.summarize(
            findings,
            collector_errors,
            len(kubernetes) + len(prometheus),
        )

        self.assertEqual([], collector_errors)
        self.assertEqual("healthy", summary["overall_status"])
        self.assertEqual("complete", summary["collection_status"])
        self.assertEqual(0, summary["finding_count"])
        self.assertEqual(0, summary["collector_error_count"])

    def test_degraded_summary_when_findings_exist_but_collection_is_partial(self):
        kubernetes = {
            "pods": {
                "items": [
                    {
                        "metadata": {"name": "orders-stage-123"},
                        "status": {
                            "phase": "Running",
                            "containerStatuses": [
                                {
                                    "name": "orders",
                                    "state": {"waiting": {"reason": "CrashLoopBackOff"}},
                                }
                            ],
                        },
                    }
                ]
            },
            "deployments": {"error": "deployment collector failed", "items": []},
            "hpa": {"items": []},
            "events": {"items": []},
        }
        prometheus = {
            name: {"status": "success", "data": {"result": []}}
            for name in self.agent.PROMETHEUS_QUERIES
        }

        collector_errors = self.agent.collect_collector_errors(kubernetes, prometheus)
        findings = []
        findings.extend(self.agent.analyze_pods(kubernetes["pods"]))
        findings.extend(self.agent.analyze_deployments(kubernetes["deployments"]))
        findings.extend(self.agent.analyze_hpa(kubernetes["hpa"]))
        findings.extend(self.agent.analyze_events(kubernetes["events"]))
        findings.extend(self.agent.analyze_prometheus(prometheus))

        summary = self.agent.summarize(
            findings,
            collector_errors,
            len(kubernetes) + len(prometheus),
        )

        self.assertEqual("degraded", summary["overall_status"])
        self.assertEqual("partial_failure", summary["collection_status"])
        self.assertEqual(1, summary["collector_error_count"])
        self.assertGreaterEqual(summary["finding_count"], 1)

    def test_main_exits_non_zero_when_fail_on_collector_errors_is_enabled(self):
        kubernetes = {
            "pods": {"error": "pods collector failed", "items": []},
            "deployments": {"error": "deployments collector failed", "items": []},
            "hpa": {"error": "hpa collector failed", "items": []},
            "events": {"error": "events collector failed", "items": []},
        }
        prometheus = {
            "request_rate": {
                "status": "error",
                "error": "connection refused",
                "query": "sum(retail:http_request_rate5m)",
            }
        }

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            with mock.patch.object(self.agent, "collect_kubernetes", return_value=kubernetes):
                with mock.patch.object(self.agent, "collect_prometheus", return_value=prometheus):
                    with mock.patch.object(self.agent, "generate_llm_analysis", return_value=None):
                        argv = [
                            "agent.py",
                            "--namespace",
                            "retail-store-stage",
                            "--prometheus-url",
                            "http://127.0.0.1:9090",
                            "--format",
                            "json",
                            "--fail-on-collector-errors",
                        ]
                        with mock.patch.object(sys, "argv", argv):
                            exit_code = self.agent.main()

        self.assertEqual(2, exit_code)
        report = json.loads(stdout.getvalue())
        self.assertEqual("unknown", report["summary"]["overall_status"])
        self.assertEqual("failed", report["summary"]["collection_status"])
        self.assertEqual(5, report["summary"]["collector_error_count"])
        self.assertEqual(0, report["summary"]["finding_count"])


if __name__ == "__main__":
    unittest.main()
