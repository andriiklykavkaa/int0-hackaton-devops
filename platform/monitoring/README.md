# Monitoring Stack

This directory contains the monitoring assets for the hackathon clusters.

Contents:

- `values-stage.yaml`: stage-specific Helm values for `kube-prometheus-stack`
- `values-prod.yaml`: production-oriented Helm values
- `servicemonitors/`: application scrape definitions for Retail Store services
- `rules/`: Prometheus alert rules
- `dashboards/`: Grafana dashboard ConfigMaps loaded by the Grafana sidecar

The GitHub workflow `.github/workflows/monitoring-setup.yaml` installs the
monitoring stack, applies these manifests, and performs basic health checks.
