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
GCS_BACKUP_URI=""
CHECKSUM_FILE=""
RESTORE_POD_NAME=""
RESTORE_POD_IMAGE=""
RESTORE_USER="restore_admin"
RESTORE_PASSWORD=""
SOURCE_TABLE_COUNT=""
SOURCE_ORDERS_COUNT=""
SOURCE_ORDER_ITEMS_COUNT=""
SOURCE_SHIPPING_ADDRESSES_COUNT=""
RESTORED_TABLE_COUNT=""
RESTORED_ORDERS_COUNT=""
RESTORED_ORDER_ITEMS_COUNT=""
RESTORED_SHIPPING_ADDRESSES_COUNT=""
ROW_COUNTS_MATCH="false"
RESTORE_VERIFIED="false"
UPLOADED_BACKUP_URI=""
UPLOADED_CHECKSUM_URI=""
CHECKSUM_SHA256=""
START_EPOCH="$(date +%s)"
DURATION_SECONDS=""

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
  --gcs-backup-uri <gs://bucket/prefix>       Optional GCS URI prefix for dump + checksum upload
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

random_string() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8
    return
  fi

  date +%s
}

checksum_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return
  fi

  echo "Neither sha256sum nor shasum is available." >&2
  exit 1
}

psql_scalar() {
  local pod_name="$1"
  local pg_user="$2"
  local pg_password="$3"
  local database="$4"
  local sql="$5"

  kubectl exec -n "$NAMESPACE" "$pod_name" -- \
    env PGPASSWORD="$pg_password" \
    psql -U "$pg_user" -d "$database" -At -v ON_ERROR_STOP=1 -c "$sql"
}

cleanup() {
  if [ -n "$RESTORE_POD_NAME" ]; then
    kubectl delete pod "$RESTORE_POD_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

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
    --gcs-backup-uri)
      GCS_BACKUP_URI="$2"
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
RESTORE_PASSWORD="$(random_string)"
RESTORE_POD_IMAGE="$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].image}')"

SOURCE_TABLE_COUNT="$(psql_scalar "$POD_NAME" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$DATABASE_NAME" \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('orders', 'order_items', 'shipping_addresses');")"
SOURCE_ORDERS_COUNT="$(psql_scalar "$POD_NAME" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$DATABASE_NAME" \
  "SELECT count(*) FROM orders;")"
SOURCE_ORDER_ITEMS_COUNT="$(psql_scalar "$POD_NAME" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$DATABASE_NAME" \
  "SELECT count(*) FROM order_items;")"
SOURCE_SHIPPING_ADDRESSES_COUNT="$(psql_scalar "$POD_NAME" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$DATABASE_NAME" \
  "SELECT count(*) FROM shipping_addresses;")"

if [ "$SOURCE_TABLE_COUNT" != "3" ]; then
  echo "Source database verification failed: expected 3 tables, got '$SOURCE_TABLE_COUNT'." >&2
  exit 1
fi

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
CHECKSUM_SHA256="$(checksum_sha256 "$BACKUP_FILE")"
CHECKSUM_FILE="${BACKUP_FILE}.sha256"
printf '%s  %s\n' "$CHECKSUM_SHA256" "$(basename "$BACKUP_FILE")" > "$CHECKSUM_FILE"

if [ "$ACTION" = "backup-and-restore" ]; then
  RESTORE_POD_NAME="orders-postgres-restore-$(random_string)"

  echo "Creating isolated restore target pod '$RESTORE_POD_NAME'..."
  cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${RESTORE_POD_NAME}
  labels:
    app.kubernetes.io/name: orders-postgres-restore-validation
    app.kubernetes.io/managed-by: orders-postgres-dr
spec:
  restartPolicy: Never
  containers:
    - name: postgresql
      image: ${RESTORE_POD_IMAGE}
      env:
        - name: POSTGRES_DB
          value: postgres
        - name: POSTGRES_USER
          value: ${RESTORE_USER}
        - name: POSTGRES_PASSWORD
          value: ${RESTORE_PASSWORD}
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
      ports:
        - containerPort: 5432
          name: postgresql
      volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumes:
    - name: data
      emptyDir: {}
EOF

  kubectl wait --for=condition=Ready "pod/${RESTORE_POD_NAME}" -n "$NAMESPACE" --timeout=180s

  RESTORE_POD_READY="false"
  for _ in $(seq 1 30); do
    if kubectl exec -n "$NAMESPACE" "$RESTORE_POD_NAME" -- \
      env PGPASSWORD="$RESTORE_PASSWORD" \
      pg_isready -U "$RESTORE_USER" -d postgres >/dev/null 2>&1; then
      RESTORE_POD_READY="true"
      break
    fi
    sleep 2
  done

  if [ "$RESTORE_POD_READY" != "true" ]; then
    echo "Restore target pod '$RESTORE_POD_NAME' did not become ready in time." >&2
    exit 1
  fi

  echo "Restoring backup into isolated validation database '$VALIDATION_DB'..."
  kubectl exec -n "$NAMESPACE" "$RESTORE_POD_NAME" -- \
    env PGPASSWORD="$RESTORE_PASSWORD" \
    psql -U "$RESTORE_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE \"$VALIDATION_DB\";"

  kubectl exec -i -n "$NAMESPACE" "$RESTORE_POD_NAME" -- \
    env PGPASSWORD="$RESTORE_PASSWORD" \
    pg_restore -U "$RESTORE_USER" -d "$VALIDATION_DB" --clean --if-exists --no-owner --no-privileges \
    < "$BACKUP_FILE"

  RESTORED_TABLE_COUNT="$(psql_scalar "$RESTORE_POD_NAME" "$RESTORE_USER" "$RESTORE_PASSWORD" "$VALIDATION_DB" \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('orders', 'order_items', 'shipping_addresses');")"
  RESTORED_ORDERS_COUNT="$(psql_scalar "$RESTORE_POD_NAME" "$RESTORE_USER" "$RESTORE_PASSWORD" "$VALIDATION_DB" \
    "SELECT count(*) FROM orders;")"
  RESTORED_ORDER_ITEMS_COUNT="$(psql_scalar "$RESTORE_POD_NAME" "$RESTORE_USER" "$RESTORE_PASSWORD" "$VALIDATION_DB" \
    "SELECT count(*) FROM order_items;")"
  RESTORED_SHIPPING_ADDRESSES_COUNT="$(psql_scalar "$RESTORE_POD_NAME" "$RESTORE_USER" "$RESTORE_PASSWORD" "$VALIDATION_DB" \
    "SELECT count(*) FROM shipping_addresses;")"

  if [ "$RESTORED_TABLE_COUNT" != "3" ]; then
    echo "Restore verification failed: expected 3 tables, got '$RESTORED_TABLE_COUNT'." >&2
    exit 1
  fi

  if [ "$SOURCE_ORDERS_COUNT" = "$RESTORED_ORDERS_COUNT" ] &&
    [ "$SOURCE_ORDER_ITEMS_COUNT" = "$RESTORED_ORDER_ITEMS_COUNT" ] &&
    [ "$SOURCE_SHIPPING_ADDRESSES_COUNT" = "$RESTORED_SHIPPING_ADDRESSES_COUNT" ]; then
    ROW_COUNTS_MATCH="true"
    RESTORE_VERIFIED="true"
  else
    echo "Restore verification failed: restored row counts do not match source." >&2
    echo "Source counts: orders=$SOURCE_ORDERS_COUNT order_items=$SOURCE_ORDER_ITEMS_COUNT shipping_addresses=$SOURCE_SHIPPING_ADDRESSES_COUNT" >&2
    echo "Restored counts: orders=$RESTORED_ORDERS_COUNT order_items=$RESTORED_ORDER_ITEMS_COUNT shipping_addresses=$RESTORED_SHIPPING_ADDRESSES_COUNT" >&2
    exit 1
  fi
fi

if [ -n "$GCS_BACKUP_URI" ]; then
  if ! command -v gcloud >/dev/null 2>&1; then
    echo "gcloud is required for GCS upload but is not installed." >&2
    exit 1
  fi

  GCS_BACKUP_URI="${GCS_BACKUP_URI%/}"
  UPLOADED_BACKUP_URI="${GCS_BACKUP_URI}/$(basename "$BACKUP_FILE")"
  UPLOADED_CHECKSUM_URI="${UPLOADED_BACKUP_URI}.sha256"

  echo "Uploading backup artifacts to ${GCS_BACKUP_URI}..."
  gcloud storage cp "$BACKUP_FILE" "$UPLOADED_BACKUP_URI"
  gcloud storage cp "$CHECKSUM_FILE" "$UPLOADED_CHECKSUM_URI"
fi

DURATION_SECONDS="$(( $(date +%s) - START_EPOCH ))"

if [ -n "$METADATA_OUTPUT" ]; then
  cat > "$METADATA_OUTPUT" <<EOF
ACTION=$ACTION
NAMESPACE=$NAMESPACE
POD_NAME=$POD_NAME
RESTORE_POD_NAME=$RESTORE_POD_NAME
RESTORE_POD_IMAGE=$RESTORE_POD_IMAGE
DATABASE_NAME=$DATABASE_NAME
SECRET_NAME=$SECRET_NAME
BACKUP_FILE=$BACKUP_FILE
BACKUP_SIZE_BYTES=$BACKUP_SIZE_BYTES
CHECKSUM_FILE=$CHECKSUM_FILE
CHECKSUM_SHA256=$CHECKSUM_SHA256
VALIDATION_DB=$VALIDATION_DB
SOURCE_TABLE_COUNT=$SOURCE_TABLE_COUNT
SOURCE_ORDERS_COUNT=$SOURCE_ORDERS_COUNT
SOURCE_ORDER_ITEMS_COUNT=$SOURCE_ORDER_ITEMS_COUNT
SOURCE_SHIPPING_ADDRESSES_COUNT=$SOURCE_SHIPPING_ADDRESSES_COUNT
RESTORED_TABLE_COUNT=$RESTORED_TABLE_COUNT
RESTORED_ORDERS_COUNT=$RESTORED_ORDERS_COUNT
RESTORED_ORDER_ITEMS_COUNT=$RESTORED_ORDER_ITEMS_COUNT
RESTORED_SHIPPING_ADDRESSES_COUNT=$RESTORED_SHIPPING_ADDRESSES_COUNT
ROW_COUNTS_MATCH=$ROW_COUNTS_MATCH
RESTORE_VERIFIED=$RESTORE_VERIFIED
UPLOADED_BACKUP_URI=$UPLOADED_BACKUP_URI
UPLOADED_CHECKSUM_URI=$UPLOADED_CHECKSUM_URI
DURATION_SECONDS=$DURATION_SECONDS
EOF
fi

echo "Backup completed: $BACKUP_FILE (${BACKUP_SIZE_BYTES} bytes)"
if [ "$ACTION" = "backup-and-restore" ]; then
  echo "Restore verification passed for isolated validation database '$VALIDATION_DB'."
fi
