# Terraform recipes

Each directory is a self-contained root module that runs the published
[GeoLens](https://github.com/geolens-io/geolens) images on one cloud's managed
services. No registry modules, no shared wrapper: copy the directory, set the
variables, apply.

| Recipe | Status | Manual path |
| --- | --- | --- |
| [`aws-ecs-fargate`](aws-ecs-fargate/) | Validated on a real account (2026-10-18, GeoLens 1.25.1 upgraded in place to 1.26.0). ECS Fargate, RDS PostgreSQL 17, S3, ElastiCache Valkey, ALB. | [`clouds/aws.md`](../clouds/aws.md) |
| [`azure-container-apps`](azure-container-apps/) | Validated on a real subscription (2026-10-18, GeoLens 1.25.1 upgraded in place to 1.26.0). Container Apps, PostgreSQL Flexible Server 17, Blob Storage with an Azure Files staging share, optional Azure Managed Redis. | [`clouds/azure.md`](../clouds/azure.md) |
| Google Cloud | Planned, not started: [#42](https://github.com/geolens-io/geolens-deployments/issues/42). | [`clouds/google-cloud.md`](../clouds/google-cloud.md) |
| DigitalOcean | Planned, not started: [#43](https://github.com/geolens-io/geolens-deployments/issues/43). | [`clouds/digitalocean.md`](../clouds/digitalocean.md) |

## What a recipe has to provide

The application is the same everywhere. Each recipe maps five pieces onto a
cloud:

1. A PostgreSQL 13+ instance with PostGIS, pgvector 0.5+, pg_trgm and
   unaccent, plus a one-shot job that creates the `catalog` and `data` schemas
   and the `geolens_reader` role before the first `alembic upgrade heads`.
2. Object storage. The backend speaks S3 natively and Azure Blob through
   `STORAGE_PROVIDER=azure`. S3-compatible stores work by setting
   `S3_ENDPOINT`. Only `s3` hands an upload to the worker through the bucket;
   with any other provider the api stages it at `/app/staging` and the worker
   reads it from there, so the two need a shared directory.
3. A Redis-compatible cache reachable as `REDIS_URL`. From GeoLens 1.23.0,
   importing or refreshing a service that needs a token fails without one,
   and more than one api instance needs it too; everything else runs on an
   in-process cache.
4. Four containers: the frontend edge, the api, the worker, and titiler. The
   frontend must be the only public target, and when the api and titiler share
   a network namespace titiler has to move off port 8000.
5. Somewhere to keep the JWT secret, admin password and database DSN out of
   the task definition.

## Notes for the planned recipes

[`clouds/`](../clouds/) covers the managed services themselves, one page per
cloud, with the environment variables each one needs. What is left here is the
container topology each runtime forces, which is a recipe decision rather than
a provisioning one.

Google Cloud: Cloud Run multi-container services cover the frontend, api and
titiler. The worker is a long-running process, so it belongs in its own
service with CPU always allocated and minimum instances 1, or on a small GCE
VM. Reaching a private Cloud Run service needs a Google-signed ID token that
neither the nginx proxy hop nor the api's titiler client mints.

DigitalOcean: App Platform has no sidecar concept, so the api and titiler
become separate components with internal routing and `TITILER_BASE_URL`
pointed at the titiler component.

A recipe landing is the moment to correct the cloud page beside it, since the
recipe is what proves the prose.

## Validating a recipe change

A change to what an apply creates, or to the settings a container ends up
with, is tried on a real account before it merges. The run upgrades a stack in
place, since that is what an operator does, and leaves nothing behind.

1. Copy the recipe and the smoke script to a scratch directory outside the
   repository, so no state or tfvars land in a checkout. For a version bump
   that is `origin/main`; for a recipe change, start from `origin/main` and
   copy the branch's recipe over it at step 4.

   ```sh
   scratch=$(mktemp -d)
   git archive origin/main terraform/<recipe> .github/ci | tar -x -C "$scratch"
   ```

2. Work in `$scratch/terraform/<recipe>`; the scripts below are under
   `$scratch/.github/ci/`. Write `terraform.tfvars` there with a short unused
   `name`, the previous release as `geolens_version`, and for AWS
   `skip_final_snapshot = true` and `s3_force_destroy = true`, so the stack
   can be destroyed outright.
3. `terraform init && terraform apply`, then take a baseline:
   `curl -sf "$url/api/health"` and
   `.github/ci/ingest-smoke.sh "$url" admin "$password"`, with `url` from
   `terraform output -raw app_url` and the password from
   `eval "$(terraform output -raw admin_password_command)"`.
4. Change only `geolens_version` (or copy in the branch's recipe) and apply on
   the same state while polling `/api/health` every 10 seconds. Every poll
   should answer 200.
5. Confirm the migrate step ran the new revisions: on AWS,
   `aws logs tail /ecs/<name>-migrate --since 1h`; on Azure,
   `az containerapp job logs show --resource-group <name>-rg --name <name>-migrate --execution <execution> --container migrate`,
   with the execution from `az containerapp job execution list`.
6. Check that the baseline's datasets still serve their collection items and
   raster tile, then run `ingest-smoke.sh` again.
7. `terraform destroy`. On Azure, run it until it completes; Teardown in the
   recipe README explains the four runs.
8. Sweep for leftovers. Every `LEFT` line is something to delete by hand:

   ```sh
   .github/ci/sweep-aws.sh <name> <region>
   .github/ci/sweep-azure.sh <name> <subscription-id>
   ```

   On AWS, force-delete the secret the sweep notes in its recovery window.
9. Delete the scratch directory. Its state holds the generated secrets.
10. Record the run in the recipe README's "Validated" section and in the PR:
    date, region, the versions, and what was checked.
