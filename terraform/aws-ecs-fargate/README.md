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
- An AWS account and credentials with permission to create VPC, ECS, RDS,
  ElastiCache, S3, IAM and Secrets Manager resources
- A remote state backend for anything beyond a trial. The module declares
  none, so state is local until you add an S3 backend block; that state holds
  the generated database password and JWT secret.

## Quick start

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

Without a certificate the load balancer serves plain HTTP, so that password
crosses the internet in clear text, and OAuth sign-in will not work because
the production cookie flag requires HTTPS. Treat an HTTP deployment as a trial
and add a certificate before real use.

## Custom domain and TLS

Request an ACM certificate in the same region, then set both of these:

```hcl
acm_certificate_arn = "arn:aws:acm:us-east-1:111122223333:certificate/..."
public_app_url      = "https://geolens.example.com"
```

Apply, then point an alias record for your domain at the
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
  two, or the uvicorn worker count, needs a larger class or an external
  pooler.
- `worker_ephemeral_storage_gb` is the worker's scratch disk. With S3 storage
  the api never keeps an upload, but the worker pulls a raster down to convert
  it, so a large GeoTIFF plus its COG must fit; Fargate allows up to 200 GiB.

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
- The RDS master user is the application user, so migrations can create
  schemas and extensions without a second role.
- One task role is shared by every container, which lets titiler write to the
  bucket even though it only reads.
- The database is single-AZ, the cache is one node, and the bucket has
  versioning off.

## Cost

Roughly $100 a month at the defaults: about $12 for RDS, $12 for ElastiCache,
$60 for 2 vCPU and 7 GB of Fargate, $16 and up for the load balancer, and a few
dollars for S3 and logs. Omitting the NAT gateway saves about $32.

## Backups and restore

RDS keeps seven days of automated backups and the bucket has no versioning.
Restoring means a point-in-time restore of the RDS instance and, if objects
were deleted, whatever you have kept outside this module. The procedure for a
managed PostgreSQL is section 3 of the GeoLens
[RUNBOOK](https://github.com/geolens-io/geolens/blob/main/RUNBOOK.md).

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

## Validated

Deployed, smoke tested and destroyed against a real AWS account three times
on 2026-09-07 with GeoLens 1.18.1. The first run proved the data path: dataset
upload through the CLI, ingestion by the worker, objects written to S3, and
features read back from the collection items endpoint. The last run, on the
final module, saw the api, titiler and worker containers pass their health
checks, both deployments complete without a rollback, and a browser sign-in
whose admin overview reported the external database, S3 storage and Redis
cache all healthy.
