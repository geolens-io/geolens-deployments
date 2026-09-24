# GeoLens on Azure Container Apps

Terraform for running [GeoLens](https://github.com/geolens-io/geolens) on Azure
with managed services only. There is no cluster to operate and no server to
patch, and it pulls the published images straight from ghcr.io.

This is a community recipe, maintained on a best-effort basis like the Helm
chart. Docker Compose is still the primary documented install path.
[`clouds/azure.md`](../../clouds/azure.md) is the manual counterpart.

## What it deploys

```
                        internet
                           |
          Container Apps ingress  https://<name>-app.<env>.azurecontainerapps.io
                           |
   +-----------------------+-------- Container Apps environment ----------+
   |  app (1 replica, 1.75 vCPU / 3.5 GiB)                                 |
   |    frontend  nginx :8080   <- the ingress target                      |
   |    api       uvicorn :8000 <- reached over 127.0.0.1                  |
   |    titiler   uvicorn :8081 <- reached over 127.0.0.1                  |
   |                                                                       |
   |  worker (1 replica, 1 vCPU / 2 GiB, no ingress)                       |
   |  migrate (a job, run by Terraform before the apps roll)               |
   +-----------------------------------------------------------------------+
         |  virtual network                |  /app/staging (api, worker)
   PostgreSQL Flexible Server 17     Storage account             Azure Managed Redis
   (private access only)             blob: datasets, rasters     (optional)
                                     file share: staging
                                     (this subnet only)
```

The frontend container is the application edge. It serves the single-page app,
proxies `/api` and `/raster-tiles` to the api, blocks `/api/metrics`, and rate
limits anonymous raster traffic. It is the only container with ingress.

Uploads reach the worker through a shared directory, not through Blob Storage:
only `STORAGE_PROVIDER=s3` hands an upload over through the bucket. The api and
the worker therefore both mount an Azure Files share at `/app/staging`, the
counterpart of the Helm chart's staging claim.

The migrate job creates the extensions, schemas and reader role, then runs
`alembic upgrade heads`. The Flexible Server administrator is not a superuser,
so around the upgrade it lends the tenant provisioner role the two privileges
the GeoLens RUNBOOK gives a non-superuser migrator, and takes them back
afterwards whether or not the upgrade succeeded. Terraform starts the job
through the Azure CLI and waits for it before the apps roll.

Container Apps terminates TLS on its own hostname and redirects plain HTTP, so
the deployment is HTTPS from the first apply. The database has no public
endpoint, and the storage account refuses anything but the Container Apps
subnet, even a request signed with its own key.

## Prerequisites

- Terraform 1.9 or newer
- The Azure CLI, logged in (`az login`) to the subscription you deploy into.
  The migrate step shells out to it, and the admin password output reads a
  secret through it.
- Contributor on the subscription, which covers creating the resources and
  registering their resource providers.
- A region where your subscription may create a Flexible Server. Many
  subscriptions are barred from the busiest regions, eastus, eastus2 and
  westus2 among them, and the create fails only after the network is up.
  Check first:

  ```sh
  az postgres flexible-server list-skus --location westus3 \
    --query "[0].{restricted:restricted, reason:reason}"
  ```

  An empty `reason` means the region is open to you.

  Container Apps has its own capacity limits. A region under pressure fails
  the environment with `ManagedEnvironmentCapacityHeavyUsageError` a few
  minutes in, and leaves a `Failed` environment behind that Terraform does not
  track. Delete it (`az containerapp env delete --name <name>-env
  --resource-group <name>-rg --yes`, which takes about ten minutes) before you
  retry or destroy, then try another region.
- A remote state backend before storing real data. The module declares none;
  its state holds the database password, JWT secret, stored-secret encryption
  key, storage account key and admin password.

## Quick start

```sh
cp terraform.tfvars.example terraform.tfvars   # set subscription_id
terraform init
terraform apply
```

The first apply takes about ten minutes, most of it waiting for the database
(and for the cache, when it is on).

Then read the generated admin password and open the app:

```sh
eval "$(terraform output -raw admin_password_command)"
terraform output app_url
```

Log in as the user in `admin_username`, default `admin`.

## Custom domain

The app already serves HTTPS on its own hostname. To put your domain in front
of it, create two DNS records, bind the domain, then tell GeoLens its new
origin:

```sh
# CNAME  geolens.example.com        -> terraform output app_hostname
# TXT    asuid.geolens.example.com  -> terraform output custom_domain_verification_id
az containerapp hostname add  --resource-group <name>-rg --name <name>-app --hostname geolens.example.com
az containerapp hostname bind --resource-group <name>-rg --name <name>-app --hostname geolens.example.com \
  --environment <name>-env --validation-method CNAME
```

`bind` issues a free managed certificate. Once the domain answers, set
`public_app_url = "https://geolens.example.com"` and apply. That value feeds
every URL the api hands out and the OAuth redirects, so set it only once the
domain resolves. Terraform does not manage the binding: a certificate that
Azure is still issuing would otherwise stall the apply.

## Upgrading GeoLens

Bump `geolens_version` and apply. The migrate job's image changes, so the
migration runs again against the new image, and only then do the apps roll
onto a new revision. Container Apps keeps the old revision serving until the
new one is ready, but Terraform does not wait for that, so check it after an
apply:

```sh
az containerapp revision list --resource-group <name>-rg --name <name>-app \
  --query "[?properties.active].{revision:name, health:properties.healthState}" --output table
```

## Configuration

The variables cover the infrastructure and the application settings a first
install usually changes. Everything else GeoLens reads from the environment
goes through two escape hatches, the same way the Helm chart's `extraEnv` and
`existingSecret` work.

`extra_env` is a map of plain settings for the api, worker and migrate
containers. An entry overrides a default of the same name. `extra_secrets` is
a map of secret settings, env name to value, stored as Container Apps secrets
and passed by reference, so the portal shows the name and not the value.

```hcl
extra_env = {
  REGISTRATION_ENABLED = "true"
  OPENAI_MODEL         = "gpt-4o"
  SMTP_HOST            = "smtp.example.com"
  SMTP_FROM_ADDRESS    = "geolens@example.com"
}

extra_secrets = {
  OPENAI_API_KEY = "sk-..."
  SMTP_PASSWORD  = "..."
}
```

The [configuration reference](https://docs.getgeolens.com/guides/quickstart/configuration/)
lists every setting. Neither map may name one of the recipe's own secrets
(`DATABASE_URL_OVERRIDE`, `JWT_SECRET_KEY`, the two `GEOLENS_ADMIN_*` values,
`SECRET_ENCRYPTION_KEY`, `AZURE_STORAGE_ACCOUNT_KEY`, `REDIS_URL`) or the two
variables it keeps for itself (`SECRETS_REVISION`, `GEOLENS_BOOTSTRAP_B64`),
and no name may appear in both; the plan fails instead.

Container Apps keeps running replicas on the old value of a changed secret.
The recipe renders a digest of every secret value into the templates, so any
secret change, yours or its own, rolls a new revision and re-runs the migrate
job. There is no revision counter to bump.

The recipe generates `SECRET_ENCRYPTION_KEY`, the dedicated key for the
secrets GeoLens stores such as SSO client secrets, so rotating the JWT secret
does not make them unreadable. Do not replace
`random_bytes.secret_encryption_key` to rotate it; that strands what it
encrypted.

`upload_max_size_mb` is rendered into both the api and the frontend edge, so
the two limits cannot drift apart. On Azure every upload streams through the
api: presigned uploads are an S3-only path.

## Scaling

- `app_replicas` runs more copies of the app. More than one needs
  `cache_enabled = true`; the plan refuses otherwise, since each api would
  keep its own in-memory cache.
- `worker_concurrency` adds parallel job slots in the one worker. Raise
  `worker_cpu` with it.
- `api_cpu` and `worker_cpu` set vCPU, and each container gets twice that in
  GiB of memory, the ratio Consumption allows. The worker default of 2 GiB
  handles modest rasters; GDAL ingestion of large ones wants more.
- `db_sku_name` and `db_storage_mb` size the database. Azure grows a disk but
  never shrinks one.

## What is deliberately simplified

Every shortcut is marked with a `# ponytail:` comment naming its ceiling.

- The frontend, api and titiler run in one app. They share a network namespace
  and talk over loopback, so there is no service discovery to run, but they
  cannot scale independently.
- The database administrator is both the migration and the application login.
- The cache is one node on a public endpoint, protected by TLS and its access
  key. A private endpoint and high availability are the upgrade.
- Secrets live in Container Apps and in Terraform state rather than in Key
  Vault. Key Vault references are the upgrade when rotation and auditing need
  to happen outside Terraform.
- Staging is an SMB share, so the worker's raster conversions write over the
  network. A premium NFS share is the upgrade when ingest throughput matters.
- Neither app scales to zero. The api takes the better part of a minute to
  start, which is a long wait for a first request.

## Cost

Roughly $100 a month at the defaults in westus3 when the app is mostly idle,
and up to about $250 under constant load, at list prices from the Azure Retail
Prices API in September 2026. Container Apps bills a replica at a lower rate
while it is idle: the app's 1.75 vCPU and 3.5 GiB come to $41 idle and $138
busy, the worker's 1 vCPU and 2 GiB to $24 and $79, less about $5 of monthly
free grant. The rest is steady: $16 for PostgreSQL B1ms with its 32 GiB, about
$22 for the load balancer and public IP the environment puts in its
infrastructure resource group, and a few dollars for logs, blobs and the
staging share. The cache adds about $12 a month.

## Backups and restore

Flexible Server keeps automated backups for `backup_retention_days` (7 by
default, up to 35) and restores to any point in that window, always into a new
server:

```sh
az postgres flexible-server restore --resource-group <name>-rg \
  --name <new-server> --source-server <server> \
  --restore-time 2026-09-23T12:00:00Z
```

The new server has a new name, and this module generates the DSN from its own
server, so repointing the stack at a restored database is a manual step:
follow section 3 of the GeoLens [RUNBOOK](https://github.com/geolens-io/geolens/blob/v1.20.0/RUNBOOK.md)
for the managed-PostgreSQL restore, and rehearse it before you rely on it.
Blob Storage has no versioning or soft delete here; turn them on if you want
them.

To guard the data against a stray delete, an Owner can lock the resource
group:

```sh
az lock create --name geolens-no-delete --lock-type CanNotDelete \
  --resource-group <name>-rg
```

A Contributor can then delete nothing in it, their `terraform destroy`
included. Contributors cannot create or remove locks, which is why the recipe
does not manage this one; an Owner running `terraform destroy` has to delete
the lock first.

## Teardown

```sh
terraform destroy
```

This deletes the resource group and everything in it: the database with its
backups, and the storage account with every blob and the staging share. The
environment's infrastructure group, `<name>-rg-infra`, goes with the
environment, and the Log Analytics workspace is purged rather than
soft-deleted, so its name is free for the next apply. Take a restore point or
copy the data first if you need it.

azurerm 5.6 reports every Container App, job and environment delete as a
failure, `polling after Delete: ... Content-Type "" was not implemented`,
although the delete goes through
([hashicorp/terraform-provider-azurerm#33433](https://github.com/hashicorp/terraform-provider-azurerm/issues/33433)).
Each report stops the destroy, so run it until it completes. Expect four runs:
the first stops at the apps, the second at the job, the third at the
environment after about twenty minutes, and the fourth removes the rest.

If the region had no Network Watcher yet, creating the virtual network made
Azure add `NetworkWatcher_<region>` to `NetworkWatcherRG`. Terraform does not
manage it, so it stays after the destroy. It costs nothing and serves every
virtual network in the region.

## Validated

Applied to a real subscription on 2026-09-23 in westus3 with GeoLens 1.20.0,
first with the cache on and then with it off, and destroyed. Each time
`/api/health` reported the database, storage and cache over HTTPS, and
`.github/ci/ingest-smoke.sh` ingested a vector and a raster through the edge
and fetched a tile. A browser signed in, imported a GeoJSON through the UI and
rendered the raster. Plain HTTP redirected to HTTPS, `/api/metrics` returned
404 at the edge, a Blob request signed with the account key from outside Azure
was refused by the network rules, the database name resolved only inside the
virtual network, and the edge logged the real client address and ignored a
spoofed `X-Forwarded-For`.
