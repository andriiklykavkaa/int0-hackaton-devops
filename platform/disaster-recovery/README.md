# Disaster Recovery

This directory contains the stateful disaster recovery workflow for the `orders` PostgreSQL database in `stage` and `prod`.

## Scope

- Stateful component: `orders` PostgreSQL
- Environments:
  - `retail-store-stage` in `squad-ecommerce-stage`
  - `retail-store-prod` in `squad-ecommerce-prod`
- Scenario: create a logical backup, restore it into an isolated temporary PostgreSQL target, and verify restored schema plus row counts

The restore step is intentionally non-destructive. It does not overwrite the live `orders` database and does not restore into the live PostgreSQL instance.

## Workflow

Run the manual GitHub Actions workflow [`.github/workflows/disaster-recovery-orders.yaml`](/Users/david/DevOpsHackathon/int0-hackaton-devops/.github/workflows/disaster-recovery-orders.yaml).

The same workflow also runs on a daily schedule:

- `03:00 UTC`: `stage`
- `04:00 UTC`: `prod`

Inputs:

- `environment`: `stage` or `prod`
- `action`: `backup-only` or `backup-and-restore`
- `validation_db`: defaults to `orders_restore_validation`
- `backup_bucket`: optional GCS bucket name or `gs://` URI prefix for durable dump retention

The workflow will:

1. Connect to the selected GKE cluster.
2. Resolve the target namespace from the selected environment.
3. Find the running `orders` PostgreSQL pod.
4. Query source row counts from `orders`, `order_items`, and `shipping_addresses`.
5. Create a PostgreSQL custom-format dump artifact and a SHA256 checksum.
6. Optionally upload the dump and checksum to GCS for durable retention.
7. Optionally restore the dump into an isolated temporary PostgreSQL pod and validation database.
8. Verify that `orders`, `order_items`, and `shipping_addresses` exist after restore and that restored row counts match the source.
9. Publish a GitHub job summary and upload the dump, checksum, and metadata as artifacts.

## Demo Flow

1. Create a little data in the storefront so the `orders` database is non-empty.
2. Run `Orders PostgreSQL Disaster Recovery` with `action=backup-and-restore`.
3. Show the job summary:
   - backup file created
   - checksum created
   - restore verified in isolated target
   - source and restored row counts match
   - optional GCS upload path
4. Download the artifact to show the actual backup file and checksum exist.

## Notes

- The DR workflow assumes the selected environment deploys `orders` with `app.persistence.provider=postgres`, `postgresql.create=true`, and a persistent volume.
- If no running PostgreSQL pod exists, the workflow fails fast instead of pretending the backup succeeded.
- To enable durable retention, set repository secret `DR_GCS_BUCKET` to either a bucket name such as `my-dr-backups` or a `gs://` URI prefix.
- For the strongest demo, seed a few real orders before running DR so the restored counts are non-zero and visually convincing.
