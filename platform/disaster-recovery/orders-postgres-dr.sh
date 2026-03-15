#!/usr/bin/env bash
set -euo pipefail

ACTION="backup-and-restore"
NAMESPACE="retail-store-stage"
BACKUP_FILE=""
METADATA_OUTPUT=""
VALIDATION_DB="orders_restore_validation"
DATABASE_NAME="orders"
SECRET_NAME="orders-db"
POD_SELECTOR="app.kubernetes.io/component=postgresql,app.kubernetes.io/owner=retail-store-sample"

usage() {
  cat <<'EOF'
Usage: orders-postgres-dr.sh [options]

Options:
  --action <backup-only|backup-and-restore>   DR action to run. Default: backup-and-restore
  --namespace <namespace>                     Kubernetes namespace. Default: retail-store-stage
  --backup-file <path>                        Output path for the PostgreSQL custom-format dump
  --metadata-output <path>                    Output file for key=value metadata
  --validation-db <name>                      Scratch database used for restore validation
  --database-name <name>                      Source PostgreSQL database name. Default: orders
  --secret-name <name>                        Secret with PostgreSQL credentials. Default: orders-db
  --pod-selector <selector>                   Label selector for the PostgreSQL pod
  --help                                      Show this help
EOF
}

decode_base64() {
  if command -v base64 >/dev/null 2>&1; then
    if printf '%s' "$1" | base64 --decode >/dev/null 2>&1; then
      printf '%s' "$1" | base64 --decode
      return
    fi
    if printf '%s' "$1" | base64 -d >/dev/null 2>&1; then
      printf '%s' "$1" | base64 -d
      return
    fi
  fi

  echo "Failed to decode base64 payload." >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --action)
      ACTION="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --backup-file)
      BACKUP_FILE="$2"
      shift 2
      ;;
    --metadata-output)
      METADATA_OUTPUT="$2"
      shift 2
      ;;
    --validation-db)
      VALIDATION_DB="$2"
      shift 2
      ;;
    --database-name)
      DATABASE_NAME="$2"
      shift 2
      ;;
    --secret-name)
      SECRET_NAME="$2"
      shift 2
      ;;
    --pod-selector)
      POD_SELECTOR="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$ACTION" in
  backup-only|backup-and-restore)
    ;;
  *)
    echo "Unsupported action: $ACTION" >&2
    exit 1
    ;;
esac

if [ -z "$BACKUP_FILE" ]; then
  BACKUP_FILE="/tmp/orders-postgres-$(date +%Y%m%d%H%M%S).dump"
fi

mkdir -p "$(dirname "$BACKUP_FILE")"

POD_NAMES="$(kubectl get pods -n "$NAMESPACE" -l "$POD_SELECTOR" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
POD_NAME="$(printf '%s\n' "$POD_NAMES" | sed '/^$/d' | head -n 1)"

if [ -z "$POD_NAME" ]; then
  echo "No running PostgreSQL pod found in namespace '$NAMESPACE' with selector '$POD_SELECTOR'." >&2
  exit 1
fi

POSTGRES_USER_B64="$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.RETAIL_ORDERS_PERSISTENCE_USERNAME}')"
POSTGRES_PASSWORD_B64="$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.RETAIL_ORDERS_PERSISTENCE_PASSWORD}')"

if [ -z "$POSTGRES_USER_B64" ] || [ -z "$POSTGRES_PASSWORD_B64" ]; then
  echo "Secret '$SECRET_NAME' in namespace '$NAMESPACE' does not contain PostgreSQL credentials." >&2
  exit 1
fi

POSTGRES_USER="$(decode_base64 "$POSTGRES_USER_B64")"
POSTGRES_PASSWORD="$(decode_base64 "$POSTGRES_PASSWORD_B64")"

echo "Creating PostgreSQL backup from pod '$POD_NAME' in namespace '$NAMESPACE'..."
kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
  env PGPASSWORD="$POSTGRES_PASSWORD" \
  pg_dump -U "$POSTGRES_USER" -d "$DATABASE_NAME" -Fc --clean --if-exists --no-owner --no-privileges \
  > "$BACKUP_FILE"

if [ ! -s "$BACKUP_FILE" ]; then
  echo "Backup file '$BACKUP_FILE' is empty." >&2
  exit 1
fi

BACKUP_SIZE_BYTES="$(wc -c < "$BACKUP_FILE" | tr -d '[:space:]')"
TABLE_COUNT=""
ORDERS_COUNT=""
ORDER_ITEMS_COUNT=""
SHIPPING_ADDRESSES_COUNT=""
RESTORE_VERIFIED="false"

if [ "$ACTION" = "backup-and-restore" ]; then
  echo "Restoring backup into validation database '$VALIDATION_DB'..."
  kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    env PGPASSWORD="$POSTGRES_PASSWORD" \
    psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$VALIDATION_DB' AND pid <> pg_backend_pid();" \
    -c "DROP DATABASE IF EXISTS \"$VALIDATION_DB\";" \
    -c "CREATE DATABASE \"$VALIDATION_DB\";"

  kubectl exec -i -n "$NAMESPACE" "$POD_NAME" -- \
    env PGPASSWORD="$POSTGRES_PASSWORD" \
    pg_restore -U "$POSTGRES_USER" -d "$VALIDATION_DB" --clean --if-exists --no-owner --no-privileges \
    < "$BACKUP_FILE"

  TABLE_COUNT="$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    env PGPASSWORD="$POSTGRES_PASSWORD" \
    psql -U "$POSTGRES_USER" -d "$VALIDATION_DB" -At -c \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('orders', 'order_items', 'shipping_addresses');")"
  ORDERS_COUNT="$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    env PGPASSWORD="$POSTGRES_PASSWORD" \
    psql -U "$POSTGRES_USER" -d "$VALIDATION_DB" -At -c "SELECT count(*) FROM orders;")"
  ORDER_ITEMS_COUNT="$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    env PGPASSWORD="$POSTGRES_PASSWORD" \
    psql -U "$POSTGRES_USER" -d "$VALIDATION_DB" -At -c "SELECT count(*) FROM order_items;")"
  SHIPPING_ADDRESSES_COUNT="$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    env PGPASSWORD="$POSTGRES_PASSWORD" \
    psql -U "$POSTGRES_USER" -d "$VALIDATION_DB" -At -c "SELECT count(*) FROM shipping_addresses;")"

  if [ "$TABLE_COUNT" = "3" ]; then
    RESTORE_VERIFIED="true"
  else
    echo "Restore verification failed: expected 3 tables, got '$TABLE_COUNT'." >&2
    exit 1
  fi
fi

if [ -n "$METADATA_OUTPUT" ]; then
  cat > "$METADATA_OUTPUT" <<EOF
ACTION=$ACTION
NAMESPACE=$NAMESPACE
POD_NAME=$POD_NAME
DATABASE_NAME=$DATABASE_NAME
SECRET_NAME=$SECRET_NAME
BACKUP_FILE=$BACKUP_FILE
BACKUP_SIZE_BYTES=$BACKUP_SIZE_BYTES
VALIDATION_DB=$VALIDATION_DB
TABLE_COUNT=$TABLE_COUNT
ORDERS_COUNT=$ORDERS_COUNT
ORDER_ITEMS_COUNT=$ORDER_ITEMS_COUNT
SHIPPING_ADDRESSES_COUNT=$SHIPPING_ADDRESSES_COUNT
RESTORE_VERIFIED=$RESTORE_VERIFIED
EOF
fi

echo "Backup completed: $BACKUP_FILE (${BACKUP_SIZE_BYTES} bytes)"
if [ "$ACTION" = "backup-and-restore" ]; then
  echo "Restore verification passed for validation database '$VALIDATION_DB'."
fi
