# Disaster Recovery

This directory contains the stateful disaster recovery demo for the `orders` PostgreSQL database in `stage`.

## Scope

- Stateful component: `orders` PostgreSQL
- Environment: `retail-store-stage` in `squad-ecommerce-stage`
- Scenario: create a backup, restore it into a scratch validation database, and verify the restored schema/data

The restore step is intentionally non-destructive. It does not overwrite the live `orders` database.

## Workflow

Run the manual GitHub Actions workflow [`.github/workflows/disaster-recovery-orders.yaml`](/Users/david/DevOpsHackathon/int0-hackaton-devops/.github/workflows/disaster-recovery-orders.yaml).

Inputs:

- `action`: `backup-only` or `backup-and-restore`
- `namespace`: defaults to `retail-store-stage`
- `validation_db`: defaults to `orders_restore_validation`

The workflow will:

1. Connect to the stage GKE cluster.
2. Find the running `orders` PostgreSQL pod.
3. Create a PostgreSQL custom-format dump artifact.
4. Optionally restore the dump into `orders_restore_validation`.
5. Verify that `orders`, `order_items`, and `shipping_addresses` exist after restore.
6. Publish a GitHub job summary and upload the dump plus metadata as artifacts.

## Demo Flow

1. Create a little data in the storefront so the `orders` database is non-empty.
2. Run `Orders PostgreSQL Disaster Recovery` with `action=backup-and-restore`.
3. Show the job summary:
   - backup file created
   - restore verified
   - row counts present
4. Download the artifact to show the actual backup file exists.

## Notes

- The DR workflow assumes `stage` deploys `orders` with `app.persistence.provider=postgres`, `postgresql.create=true`, and a persistent volume.
- If no running PostgreSQL pod exists, the workflow fails fast instead of pretending the backup succeeded.
