# AIOps Agent

This directory contains a lightweight AIOps agent for the hackathon.

Current scope:

- collect Kubernetes runtime signals from `kubectl`
- collect key Prometheus signals from the monitoring stack
- produce a compact incident summary with severity and recommended actions

The current implementation is deterministic and does not require an LLM yet.
That makes it safe to test locally before wiring in AI-based diagnosis.

## Usage

Run against a live cluster:

```bash
python3 platform/aiops/agent.py \
  --environment stage \
  --namespace retail-store-stage \
  --prometheus-url http://localhost:9090
```

Write the full JSON report:

```bash
python3 platform/aiops/agent.py \
  --namespace retail-store-stage \
  --prometheus-url http://localhost:9090 \
  --output /tmp/aiops-report.json
```

Run with local sample data:

```bash
python3 platform/aiops/agent.py \
  --environment stage \
  --namespace retail-store-stage \
  --mock-dir platform/aiops/fixtures/sample
```

Run with optional AI diagnosis using an OpenAI-compatible endpoint:

```bash
AIOPS_OPENAI_BASE_URL=http://localhost:11434/v1 \
AIOPS_OPENAI_MODEL=llama3.1 \
AIOPS_OPENAI_API_KEY=dummy \
python3 platform/aiops/agent.py \
  --environment stage \
  --namespace retail-store-stage \
  --mock-dir platform/aiops/fixtures/sample \
  --enable-llm-analysis
```

## Signals

Kubernetes:

- pods
- deployments
- HPA objects
- recent warning events

Prometheus:

- request rate
- error rate
- p95 latency
- pod restarts
- CPU throttling
- scrape target health
- RabbitMQ backlog

## Next Step

The next iteration should wire this agent into a manual GitHub Actions workflow
so it can authenticate to GKE, query Prometheus, and publish the incident
summary directly in CI.

## GitHub Actions

The manual workflow is [`.github/workflows/aiops-agent.yaml`](/Users/david/DevOpsHackathon/int0-hackaton-devops/.github/workflows/aiops-agent.yaml).

It does the following:

- authenticates to GCP
- gets GKE credentials for `stage` or `prod`
- port-forwards Prometheus inside the runner
- runs `platform/aiops/agent.py`
- publishes the markdown summary and JSON report as workflow output

Optional LLM mode requires these GitHub secrets:

- `AIOPS_OPENAI_BASE_URL`
- `AIOPS_OPENAI_MODEL`
- `AIOPS_OPENAI_API_KEY`
