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

1. From a checkout of this repository, copy the released recipe and
   `.github/ci` from `origin/main` to a scratch directory outside it, so no
   state or tfvars land in a checkout. The baseline is what operators run
   today.

   ```sh
   checkout=$(git rev-parse --show-toplevel)
   scratch=$(mktemp -d)
   git -C "$checkout" archive origin/main terraform/<recipe> .github/ci | tar -x -C "$scratch"
   ```

2. Work in `$scratch/terraform/<recipe>`. Write `terraform.tfvars` there with
   a short unused `name`, the previous release as `geolens_version`, and for
   AWS `skip_final_snapshot = true` and `s3_force_destroy = true`, so the
   stack can be destroyed outright.
3. Apply and take a baseline. The password stays in a variable; don't
   print it.

   ```sh
   terraform init && terraform apply
   url=$(terraform output -raw app_url)
   user=$(terraform output -raw admin_username)
   password=$(eval "$(terraform output -raw admin_password_command)")
   curl -sf "$url/api/health"
   "$scratch/.github/ci/ingest-smoke.sh" "$url" "$user" "$password"
   ```

4. Move to what is under test, on the same state. A version bump changes
   only `geolens_version` in `terraform.tfvars`. A branch that changes the
   recipe or `.github/ci` replaces both directories, so files it deletes or
   renames don't linger. Keep the tfvars, the state and `.terraform/`, and
   take the branch's `.terraform.lock.hcl`, which carries any provider pin
   it moves:

   ```sh
   r=$scratch/terraform/<recipe>
   keep=$(mktemp -d "$scratch/keep.XXXXXX")
   mv "$r/terraform.tfvars" "$r"/terraform.tfstate* "$r/.terraform" "$keep/"
   rm -rf "$r" "$scratch/.github/ci"
   git -C "$checkout" archive <branch> terraform/<recipe> .github/ci | tar -x -C "$scratch"
   mv "$keep/terraform.tfvars" "$keep"/terraform.tfstate* "$keep/.terraform" "$r/"
   cd "$r" && terraform init
   ```

   Apply while polling `/api/health` every 10 seconds. Every poll should
   answer 200.
5. Confirm the migrate step ran the new revisions: on AWS,
   `aws logs tail /ecs/<name>-migrate --since 1h`; on Azure,
   `az containerapp job logs show --resource-group <name>-rg --name <name>-migrate --execution <execution> --container migrate`,
   with the execution from `az containerapp job execution list`.
6. Check that the baseline's datasets still serve their collection items and
   raster tile, then run `ingest-smoke.sh` again with the same arguments.
7. Save what the stack owns, then `terraform destroy`. On Azure, run the
   destroy until it completes; Teardown in the recipe README explains the
   four runs.

   ```sh
   terraform state list > "$scratch/owned.txt"
   terraform show -no-color > "$scratch/owned-detail.txt"
   ```

8. Sweep for leftovers:

   ```sh
   "$scratch/.github/ci/sweep-aws.sh" <name> <region>
   "$scratch/.github/ci/sweep-azure.sh" <name> <subscription-id>
   ```

   A `LEFT` line is this stack's by exact name, region or resource group;
   delete it. A `NOTE` line is only a possible match, such as an IAM role,
   which is global, or a load balancer whose VPC is gone. Find its ID or name
   in `owned-detail.txt` before touching it, and leave it alone if it isn't
   there. The sweep exits 1 on any `LEFT` and ignores `NOTE` lines. On AWS,
   force-delete the secret the sweep notes in its recovery window.
9. Delete the scratch directory. Its state holds the generated secrets.
10. Record the run in the recipe README's "Validated" section and in the PR:
    date, region, the versions, and what was checked.
