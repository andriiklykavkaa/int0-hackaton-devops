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

The next iteration should add an LLM analysis layer that takes this structured
report and produces a more human-readable diagnosis for CI or Slack delivery.
