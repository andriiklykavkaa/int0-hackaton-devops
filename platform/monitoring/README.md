# Monitoring Stack

This directory contains the monitoring assets for the hackathon clusters.

Contents:

- `values-stage.yaml`: stage-specific Helm values for `kube-prometheus-stack`
- `values-prod.yaml`: production-oriented Helm values
- `servicemonitors/`: application scrape definitions for Retail Store services
- `exporters/`: optional dependency exporters for MySQL, PostgreSQL, Redis, and RabbitMQ
- `rules/`: Prometheus alert rules
- `dashboards/`: Grafana dashboard ConfigMaps loaded by the Grafana sidecar

The GitHub workflow `.github/workflows/monitoring-setup.yaml` installs the
monitoring stack, applies these manifests, and performs basic health checks.
Dependency exporters are only deployed when the corresponding backend service
exists in the target application namespace.
Exporter pods are hardened with non-root, read-only, and resource settings so
they comply with the repository's Kyverno policies when deployed into the
application namespace.
