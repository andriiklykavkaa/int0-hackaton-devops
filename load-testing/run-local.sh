#!/usr/bin/env bash
# Run k6 load test locally against any URL.
# Requires: k6 installed (brew install k6 / apt install k6)
#
# Usage:
#   ./load-testing/run-local.sh                           # against localhost:8888
#   ./load-testing/run-local.sh http://my-cluster-ip      # against cluster
#   ./load-testing/run-local.sh http://localhost:8888 smoke  # quick smoke (30s)

set -euo pipefail

BASE_URL="${1:-http://localhost:8888}"
MODE="${2:-full}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v k6 &>/dev/null; then
  echo "k6 not found. Install with: brew install k6"
  exit 1
fi

echo "Target : $BASE_URL"
echo "Mode   : $MODE"
echo ""

if [[ "$MODE" == "smoke" ]]; then
  BASE_URL="$BASE_URL" k6 run \
    --vus 5 \
    --duration 30s \
    --thresholds '{"http_req_duration":["p(95)<500"],"custom_error_rate":["rate<0.01"]}' \
    "$SCRIPT_DIR/scripts/retail-store.js"
else
  BASE_URL="$BASE_URL" k6 run \
    --out json="$SCRIPT_DIR/results/summary-$(date +%Y%m%d-%H%M%S).json" \
    "$SCRIPT_DIR/scripts/retail-store.js"
fi
