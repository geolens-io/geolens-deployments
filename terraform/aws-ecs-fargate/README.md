# GeoLens on AWS ECS Fargate

Terraform for running [GeoLens](https://github.com/geolens-io/geolens) on AWS
with managed services only. There is no cluster to operate and no server to
patch, and it pulls the published images straight from ghcr.io.

This is a community recipe, maintained on a best-effort basis like the Helm
chart. Docker Compose is still the primary documented install path.

## What it deploys

```
                    internet
                       |
              Application Load Balancer  :80 (:443 with a certificate)
                       |
   +-------------------+------------------- ECS Fargate ------------+
   |  app service (1 task, 1 vCPU / 3 GB)                           |
   |    frontend  nginx :8080   <- the load balancer target         |
   |    api       uvicorn :8000 <- reached over 127.0.0.1           |
   |    titiler   uvicorn :8081 <- reached over 127.0.0.1           |
   |                                                                |
   |  worker service (1 task, 1 vCPU / 4 GB)                        |
   +----------------------------------------------------------------+
                       |
     RDS PostgreSQL 17     ElastiCache Valkey      S3 bucket
     (private subnets)     (private subnets)       (datasets, rasters)
```

The frontend container is the application edge. It serves the single-page app,
proxies `/api` and `/raster-tiles` to the api, blocks `/api/metrics`, and rate
limits anonymous raster traffic. The load balancer sends everything to it and
never reaches the api directly.

A one-shot migrate task creates the extensions, schemas and reader role, then
runs `alembic upgrade heads`. It runs before the services start.

## Prerequisites

- Terraform 1.9 or newer
- AWS CLI v2, on the machine running Terraform. The migrate step shells out to
  it, using the same credentials Terraform has.
- `jq`, which the `admin_password_command` output pipes the secret through
- An AWS account and credentials with permission to create VPC, ECS, RDS,
  ElastiCache, S3, IAM and Secrets Manager resources
- A remote state backend before storing participant data. The module declares
  none by default; its state holds the database password, JWT secret and admin
  password, generated or supplied.

## Hosted pilot profile

Use [pilot.tfvars.example](pilot.tfvars.example) for one organization at a time.
Each invocation creates its own VPC, ECS services, RDS instance, S3 bucket,
Secrets Manager entry, IAM roles and optional cache. Give each organization a
unique `name` such as `geolens-city-gis` and a distinct remote-state key. This
recipe does not accept a shared/external RDS endpoint. Do not point multiple
organizations at one database; PostgreSQL roles are cluster-wide and the
recipe does not configure the database boundaries needed to share a cluster.

The opt-in `pilot_profile` validation requires a `geolens-<org-slug>` name, a
public HTTPS hostname and an ACM certificate ARN in the configured region,
RDS deletion protection, a final snapshot, at least seven days of automated
backups, versioned S3 with at least 30-day noncurrent-version retention, and
one app task and worker slot. Before applying, verify in ACM that the
certificate is `ISSUED` and covers the hostname, and create the DNS alias after
Terraform reports the load balancer name. Terraform can validate the supplied
values; it cannot prove the DNS record or certificate coverage.

### Remote state prerequisite

Provision the state bucket separately from the application bucket. Before the
first `terraform init`, require S3 versioning, SSE-KMS encryption, Block Public
Access, a TLS-only bucket policy, state locking and access limited to the
pilot operators or deployment role. Use a distinct object key for each
organization. The state contains the RDS master password, JWT key and admin
password, so state versions need the same access and retention review as
application data. Terraform 1.10 or newer is required for S3 `use_lockfile`.

From a clean copy of this module, copy and edit the example files:

```sh
cp pilot.tfvars.example terraform.tfvars
cp pilot.backend.tf.example backend.tf
cp pilot.backend.hcl.example pilot.backend.hcl
```

Replace the example hostname, certificate ARN, account ID, state bucket, KMS
key and organization slug. Give each organization's backend file a different
`key`, then initialize and review the plan:

```sh
terraform init -backend-config=pilot.backend.hcl
terraform plan -out=pilot.plan
terraform show -no-color pilot.plan
```

Keep `backend.tf`, `pilot.backend.hcl`, plan files and state out of source
control. Apply only after a reviewer confirms the target account, region,
hostname, per-organization state key and deletion controls. After apply, point
the hostname to `load_balancer_dns_name`, then verify the HTTPS URL and
`/api/health` before onboarding.

The profile gives each stack its own S3 bucket and task IAM policy, and each
stack's generated application secret is named under its `name/` path. Extra
Secrets Manager ARNs in the profile must also use that path. Pilot `extra_env`
cannot override database, migration/runtime-role, TLS, AWS credential or S3
settings. Pilot `extra_secrets` cannot replace the generated database, admin,
JWT or AWS/S3 credentials. Use provider keys only when needed, store a
separate key for each organization, and set the provider's own spend limits.

The example sets one app task, one worker slot, a 500 MB per-file upload limit,
50 GiB of fixed RDS storage, and 50 GiB of worker scratch. S3 has no total
bucket quota in this recipe, and a per-resource AWS Budget is an alert rather
than a hard stop. Activate the `Deployment` cost-allocation tag, agree S3,
database, egress and AI limits with the organization, and configure AWS Budgets
and provider-side alerts before accepting data.

### Database identity limit in release 1.20.0

GeoLens 1.20.0 supports its canonical runtime-role environment settings and
requires migrations to run separately when that mode is enabled. The published
API image does not include the repository-level `scripts/init-db.sh` or
`scripts/lib/configure-runtime-db-role.sh` helper, and this Terraform recipe's
one-shot task currently uses its own bootstrap SQL. It also supplies the RDS
master DSN to both the migrate task and the API/worker. The role separation is
therefore not wired or verified by this recipe. Keep the master credential in
this organization's Secrets Manager entry and do not reuse the RDS instance
for another organization. A follow-up must run the canonical helper inside a
private managed-database preflight and verify the deployed release before this
can claim least-privilege runtime credentials or shared-RDS support.

The current pilot is operator-managed: do not give participants the RDS
master credential, Terraform state, AWS account credentials or shared
infrastructure credentials. Record explicit operator acceptance of the
master-runtime limitation in each pilot plan before onboarding. If a
participant requires a least-privilege runtime identity, their own database
administrator identity or a shared database, wait for a deployment path that
has verified that boundary.

## Quick start for a trial

```sh
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

The first apply takes eight to ten minutes, most of it waiting for RDS.

Then read the generated admin password and open the app:

```sh
eval "$(terraform output -raw admin_password_command)"
terraform output app_url
```

Log in as the user in `admin_username`, default `admin`.

The default path uses local Terraform state and can serve plain HTTP. Use it
only with disposable trial data. Hosted participant data uses the profile
above, including remote state and HTTPS.

Plain HTTP is enough for an API or CLI smoke test, not for trying the web UI.
The browser drops the app's Secure session cookies on an `http://` origin, so a
sign-in ends when its access token expires, and the import form fails outright
because it calls `crypto.randomUUID`, which browsers only provide to HTTPS
pages. Upload through the API or the GeoLens CLI instead, or set up the
certificate below.

## Custom domain and TLS

Request an ACM certificate in the same region, then set both of these:

```hcl
acm_certificate_arn = "arn:aws:acm:us-east-1:111122223333:certificate/..."
public_app_url      = "https://geolens.example.com"
```

Both are required together: the module refuses a certificate without an
`https://` public URL. Apply, then point an alias record for your domain at the
`load_balancer_dns_name` output. Port 80 becomes a redirect to 443. Set
`public_app_url` in the same apply: it drives the S3 CORS origin and the URLs
the api hands out, and a mismatch breaks browser uploads.

## Upgrading GeoLens

Bump `geolens_version` and apply. The migrate task definition changes, so the
migration runs again against the new image, and only then do the services roll.
The circuit breaker rolls a failed deployment back to the previous task
definition.

## Configuration

The variables cover the infrastructure and the application settings that a
first install usually changes. Everything else GeoLens reads from the
environment goes through two escape hatches, the same way the Helm chart's
`extraEnv` and `existingSecret` work.

`extra_env` is a map of plain settings applied to the api, worker and migrate
containers. An entry overrides a default of the same name. `extra_secrets`
maps an env name to an ECS `valueFrom`: a Secrets Manager ARN, with an
optional `:json-key::` suffix to pick one key out of a JSON secret. The
execution role is granted read on each secret you list.

```hcl
extra_env = {
  REGISTRATION_ENABLED = "true"
  OPENAI_MODEL         = "gpt-4o"
  SMTP_HOST            = "email-smtp.us-east-1.amazonaws.com"
  SMTP_FROM_ADDRESS    = "geolens@example.com"
}

extra_secrets = {
  OPENAI_API_KEY = "arn:aws:secretsmanager:us-east-1:111122223333:secret:geolens/ai-AbCdEf:OPENAI_API_KEY::"
  SMTP_PASSWORD  = "arn:aws:secretsmanager:us-east-1:111122223333:secret:geolens/smtp-XyZ123"
}
```

The [configuration reference](https://docs.getgeolens.com/guides/quickstart/configuration/)
lists every setting. Do not put `S3_ACCESS_KEY_ID` or `S3_SECRET_ACCESS_KEY`
in either map: a static key wins over the task role and defeats the keyless
setup.

Secrets are read when a task starts. After rotating a secret named in
`extra_secrets`, bump `extra_secrets_revision` and apply: that changes every
task definition and rolls the services onto the new value. The recipe's own
secret needs no bump, its version is pinned into the task definitions. A
secret under a customer-managed KMS key works too; the execution role is
granted decrypt on that key.

`upload_max_size_mb` is rendered into both the api and the frontend edge, so
the two limits cannot drift apart.

## Scaling

- `app_desired_count` adds app tasks behind the load balancer. The api is
  stateless, so this scales reads.
- `worker_concurrency` adds parallel job slots in the one worker task. Raise
  `worker_task.cpu` with it.
- `app_task` and `worker_task` set Fargate CPU units and memory. The worker
  default is 4 GB because GDAL ingestion of large rasters needs it.
- `db_instance_class` sizes the database. The cache is `cache.t4g.micro` in
  `data.tf`. A `db.t4g.micro` allows roughly 100 connections and each api
  task is tuned for a budget of about 70, so raising `app_desired_count` past
  two, or the uvicorn worker count (`UVICORN_WORKERS`, 2, overridable through
  `extra_env`), needs a larger class or an external pooler.
- `worker_ephemeral_storage_gb` is the worker's scratch disk. With S3 storage
  the api never keeps an upload, but the worker pulls a raster down to convert
  it, so a large GeoTIFF plus its COG must fit; Fargate allows up to 200 GiB.
- `db_allocated_storage_gb` sets fixed encrypted RDS storage. The recipe does
  not configure storage autoscaling; size it for each organization's database.

## What is deliberately simplified

Every shortcut is marked with a `# ponytail:` comment naming its ceiling.

- The frontend, api and titiler run in one task. They share a network
  namespace and talk over loopback, so there is no service discovery to run,
  but they cannot scale independently. Split them into separate services with
  ECS Service Connect when that matters.
- There is no NAT gateway. Tasks run in public subnets with a public IP so they
  can pull images from ghcr.io, and their security group only accepts port 8080
  from the load balancer. A NAT gateway costs about $32 a month and buys you
  private task IPs.
- The RDS master user is both the migration and application login. The current
  1.20.0 image/recipe combination does not run the canonical managed-Postgres
  role reconciler; keep each pilot on its own RDS instance as described above.
- One task role is shared by every container, which lets titiler write to the
  bucket even though it only reads.
- The database is single-AZ and the cache is one node. Bucket versioning stays
  off on the generic path; the hosted pilot profile enables it and expires
  noncurrent versions after the configured number of days.

## Cost

Roughly $100 a month at the defaults: about $12 for RDS, $12 for ElastiCache,
$60 for 2 vCPU and 7 GB of Fargate, $16 and up for the load balancer, and a few
dollars for S3 and logs. Omitting the NAT gateway saves about $32.

## Backups and restore

The generic path keeps seven days of RDS automated backups and has no S3
versioning. The pilot profile sets 14 days of RDS automated backups and enables
S3 versions, with noncurrent versions eligible for lifecycle expiration after
30 days by default. S3 lifecycle runs asynchronously; a 30-day rule is not an
exact-time erasure promise. A delete in a versioned bucket creates a delete
marker and leaves prior data versions until lifecycle removes them. The
current S3 objects do not expire automatically.

Before participant data is stored, rehearse a restore in a temporary,
organization-specific stack:

1. Upload a synthetic dataset, wait for worker ingestion, and verify its
   metadata, features and raster tiles.
2. Restore a database recovery point to a new RDS endpoint and recover the
   corresponding S3 objects or versions. RDS recovery creates a new endpoint;
   keep the source stack available until verification is complete.
3. Follow section 3 of the GeoLens [RUNBOOK](https://github.com/geolens-io/geolens/blob/v1.20.0/RUNBOOK.md)
   for managed PostgreSQL restore steps. Verify `/api/health`, sign-in,
   collection items and raster rendering, and record the recovery point,
   endpoint change, object versions and elapsed time.
4. Test an organization-approved data export into a clean GeoLens instance.
   Confirm the exact data and application state it carries; an object bucket
   and database snapshot alone are not a complete participant handoff.

Do not onboard until an operator has recorded a successful restore and export
rehearsal for this profile. The pilot profile itself has not been applied to
AWS yet.

### Retention and deletion

- Automated RDS backups retain 14 days while the instance exists. Destroying
  the instance creates a final snapshot because `skip_final_snapshot` is false;
  that snapshot has no automatic expiration and must be reviewed and deleted
  separately when the agreed retention permits. RDS retained automated backups
  are a separate setting to inspect at deletion.
- S3 noncurrent versions become eligible for lifecycle deletion after 30 days;
  lifecycle processing is asynchronous. Current objects remain until an
  operator or the application deletes them. `s3_force_destroy` remains false,
  so versioned objects and delete markers must be removed deliberately before
  Terraform can delete the bucket.
- CloudWatch logs retain 14 days. Secrets Manager uses a seven-day recovery
  window after secret deletion.
- The Terraform state bucket keeps its own version history and retention. It
  can contain old copies of generated credentials even after a stack is gone.

The recipe provides no automatic whole-account backup erasure guarantee.
Before stating a deletion date to a participant, account for RDS snapshots and
retained automated backups, S3 versions and delete markers, state-bucket
versions, support exports and any copies held outside this stack. Record each
deletion in the organization's exit record.

## Teardown

```sh
terraform destroy
```

What the defaults do on destroy: RDS takes a final snapshot and is then
deleted (`skip_final_snapshot = true` skips the snapshot), the bucket is
deleted only if it is empty (`s3_force_destroy = true` deletes it with its
objects), and the Secrets Manager secret enters a seven-day recovery window.
Nothing stops the database from going. On an install you care about, set
`deletion_protection = true` so destroy refuses the database until you turn
it off.

For the pilot profile, teardown is a reviewed exit operation: export the agreed
data, verify the export, stop app and worker access, and wait for the retention
window before deleting stored copies. The profile's RDS deletion protection
blocks destroy until it is deliberately disabled. Empty the versioned
application bucket, including noncurrent versions and delete markers, before
destroy; `s3_force_destroy` stays false. Preserve the final RDS snapshot for the
agreed period, then remove it and any retained automated backups separately.
Apply the state bucket's retention policy to every state version as well.

## Validated

Deployed, smoke tested and destroyed against a real AWS account three times
on 2026-09-07 with GeoLens 1.18.1. The first run proved the data path: dataset
upload through the CLI, ingestion by the worker, objects written to S3, and
features read back from the collection items endpoint. The last run, on the
final module, saw the api, titiler and worker containers pass their health
checks, both deployments complete without a rollback, and a browser sign-in
whose admin overview reported the external database, S3 storage and Redis
cache all healthy.

Deployed again on 2026-09-22 with GeoLens 1.20.0, then destroyed. A raster
uploaded through the api was converted by the worker and drawn in the browser
from titiler tiles read out of S3 with the task role. The same run found two
faults and checked their fixes live (#52). The worker did not subscribe to the
`download` queue, so URL imports never started; after the fix, the import that
had waited half an hour ran at once. And with S3 access removed from the task
role, the load balancer's deep health check failed until ECS stopped the task;
on `/api/health/live` the same outage left the task running and still serving
the catalog. The pilot profile has only been statically validated; it has not
been applied or restore-tested in AWS.
