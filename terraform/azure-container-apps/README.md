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

Upgrading to 1.22.0 from an earlier release: file replacements use a new
worker task. A replacement submitted while a worker from the previous release
is still running can fail as an unknown task. Nothing is published when that
happens, so submit the replacement again once every worker runs 1.22.0.

Upgrading to 1.23.0: importing, re-uploading or refreshing a service that
needs a token now requires a cache the api and worker share. With
`cache_enabled = false` those requests answer 503
`credential_store_unavailable`. Services without a token are unaffected.

Upgrading to 1.25 from an earlier release (1.25.1 is the first with api and
worker images): migration 0083 builds its indexes on `ingest_jobs` and
`records` with `CREATE INDEX CONCURRENTLY`, which waits for open
transactions to finish and takes longer on a large catalog. The apply
waits up to an hour for the migrate job, the job's own replica timeout, while
the previous revision keeps serving. If the job fails, apply again; 0083
drops and rebuilds the invalid index an interrupted build leaves behind. If
the apply stops for another reason, such as its deadline or a failed `az`
call, the execution may still be running: check it with
`az containerapp job execution list --resource-group <name>-rg --name <name>-migrate`
and wait until it reports Succeeded, Failed or Stopped before applying again,
so two migrations never overlap. After 10 failed password sign-ins within an hour, an account answers
429 to browsers it doesn't know. To let an admin back in, open a shell in the
api container with
`az containerapp exec --resource-group <name>-rg --name <name>-app --container api`
and run `/app/.venv/bin/python -m scripts.trust_login_device <username>`,
which prints a link that works once, within 10 minutes. The [chart's notes](../../helm/geolens/README.md#migrations-and-upgrades)
on private certificate authorities and Cloudflare Web Analytics need a mounted CA
bundle or frontend env, which this recipe does not expose.

Upgrading to 1.26.0: migrations 0084 to 0086 are additive. 0085 waits at most
5 seconds for its lock on `catalog.datasets` instead of queueing behind other
writes, so on a busy catalog the migrate job can fail with a lock timeout.
The apply then stops before the apps roll, and the previous revision keeps
serving. Apply again.

Upgrading to 1.27.1: from 1.26, upgrade straight to 1.27.1 rather than 1.27.0.
1.27.0's migration 0088 drops columns that 1.26 reads, so 1.26 replicas still
serving during the rollout fail dataset requests and jobs until they are
replaced; 1.27.1 keeps those columns. Migrations 0087 to 0094 run. 0088 and
0091 to 0094 wait at most 5 seconds for their locks instead of queueing behind
other writes, so on a busy catalog the migrate job can fail with a lock
timeout. The apply then stops before the apps roll, and the previous revision
keeps serving. Apply again. 0088 moves each dataset's kept previous version
onto its version row, so rolling back below 1.27 refuses while any dataset
keeps more than one previous version. From 1.27.0, no migration runs.

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
lists every setting. A few names are off limits in both maps, and the plan
fails on any of them (`reserved_env` in `variables.tf` has the full list):

- The secrets the recipe generates: `DATABASE_URL_OVERRIDE`, `JWT_SECRET_KEY`,
  `SECRET_ENCRYPTION_KEY`, `AZURE_STORAGE_ACCOUNT_KEY`, `REDIS_URL` and the two
  `GEOLENS_ADMIN_*` values.
- Its own wiring: `SECRETS_REVISION`, `GEOLENS_BOOTSTRAP_B64`,
  `GEOLENS_API_RUN_MIGRATIONS`, `UPLOAD_STAGING_DIR`, `WORKER_SHUTDOWN_TIMEOUT`
  and the api-only `PROMETHEUS_MULTIPROC_DIR`.
- What titiler is wired to: `STORAGE_PROVIDER`, `TITILER_BASE_URL`,
  `REMOTE_RASTER_RELAY_BASE_URL` (titiler reads remote rasters through the api),
  and the storage account URL and connection string.
- The database TLS mode and the role settings GeoLens holds to the one login:
  `DATABASE_SSL_MODE`, `GEOLENS_MIGRATION_DB_ROLE` and `GEOLENS_RUNTIME_DB_ROLE`.
- `PUBLIC_APP_URL`, `PUBLIC_API_URL` and `UPLOAD_MAX_SIZE_MB`, which come from
  `public_app_url` and `upload_max_size_mb` because the frontend edge needs
  them too.

No name may appear in both maps either.

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

- `cache_enabled` creates an Azure Managed Redis instance. Since GeoLens
  1.23.0 any import, re-upload or refresh of a service that needs a token
  answers 503 without it, whatever the replica count. It stays off by default
  because it bills from the moment it exists.
- `app_replicas` is the minimum number of app replicas. More than one needs
  `cache_enabled = true`; the plan refuses otherwise, since each api would
  keep its own in-memory cache.
- `app_max_replicas` turns on autoscaling. It defaults to `app_replicas`, so
  the app stays fixed. Set it higher and Container Apps adds a replica for each
  50 concurrent HTTP requests, up to that maximum. It needs
  `cache_enabled = true` too. Every replica opens its own database
  connections, so read "Database connections" first.
- `worker_replicas` runs more copies of the worker, and `worker_concurrency`
  adds parallel job slots in each. The app tolerates several workers. Raise
  `worker_cpu` with concurrency. Replicas are fixed, since CPU is a poor
  signal for the queue; see "Scaling the worker on queue depth". On B1ms both
  stay at 1.
- `api_cpu` and `worker_cpu` set vCPU, and each container gets twice that in
  GiB of memory, the ratio Consumption allows. The worker default of 2 GiB
  handles modest rasters; GDAL ingestion of large ones wants more.
- `db_high_availability` adds a zone-redundant standby with automatic
  failover. It needs a General Purpose or Memory Optimized `db_sku_name` (the
  plan refuses a Burstable one) and a region with availability zones, and
  roughly doubles the compute cost. Connections drop during a failover, so
  requests in flight fail. To add a standby to a server that is already
  Burstable, apply the new `db_sku_name` first and set `db_high_availability`
  in a second apply. Azure checks the standby against the SKU the server has
  now, so making both changes in one apply fails with
  `HANotSupportedForBurstableSku`. The SKU change restarts the server and took
  GeoLens offline for about seven minutes in testing, so schedule it.
- `db_sku_name` and `db_storage_mb` size the database. `db_storage_mb` is the
  initial size only: auto-grow is on, so the server grows its own disk before
  it fills, and Terraform ignores the size afterwards. Azure never shrinks a
  disk. To grow it yourself, use the portal or
  `az postgres flexible-server update`.
- `zone_redundancy_enabled` spreads the Container Apps environment across
  availability zones. It is off by default and Azure fixes it when the
  environment is created: turning it on for an existing stack makes Terraform
  replace the environment, and with it both apps and the migrate job, which
  means downtime and a new app hostname. Microsoft also asks for at least two
  replicas to get any spread, so pair it with `app_replicas = 2` and
  `cache_enabled = true`. The environment subnet only has to be a `/27` or
  larger, and this recipe gives it a `/24`. It costs nothing extra. The
  database is separate: use `db_high_availability`.

### Database connections

`B_Standard_B1ms`, the default, allows 50 connections and Azure reserves 15,
leaving 35. On B1ms the recipe runs one api process (`UVICORN_WORKERS=1`,
without `UVICORN_MAX_REQUESTS`, which would stop the only process) and sets,
for the api, `DB_POOL_SIZE=2`, `DB_MAX_OVERFLOW=0` and `TILE_POOL_MIN_SIZE`
and `TILE_POOL_MAX_SIZE` of 1, and for the worker
`DB_POOL_SIZE=worker_concurrency` and `DB_MAX_OVERFLOW=0`. `extra_env`
overrides the pool settings. Per process the worst case is
`DB_POOL_SIZE + DB_MAX_OVERFLOW + 3` for the job queue connector, plus one
held for readiness probes, `TILE_POOL_MAX_SIZE` in the api and one connection
that listens for jobs in the worker:

```
api     1 process   x (2 + 0 + 1 + 3 + 1)         =  7
worker  1 replica   x (1 + 0 + 3 + 1 + 1)         =  6
one revision                                      = 13
a rolling revision runs old and new together      = 26   (limit 35)
```

GeoLens 1.26.0 holds no readiness connection, so it uses one fewer in each
process. The cost is one tile render at a time in the api. B1ms has room for
one app replica with one api process and one worker with one job slot, so the
plan refuses `app_replicas`, `app_max_replicas`, `worker_replicas` or
`worker_concurrency` above 1 on it, and `UVICORN_WORKERS` above 1 or any
`UVICORN_MAX_REQUESTS` in `extra_env` or `extra_secrets`. Larger SKUs get the
app defaults, which fit their much higher limits; the
[connection budget](../../clouds/README.md#database-connections) has the
formula.

To scale out, move to a larger `db_sku_name`. Flexible Server's built-in
PgBouncer can't be used with GeoLens yet, because the job queue sets its
`search_path` through the `options` startup parameter, which PgBouncer rejects.
This is a GeoLens limitation, tracked in
[geolens#3213](https://github.com/geolens-io/geolens/issues/3213).

### Uploads and the ingress timeout

Container Apps ingress closes a request that takes longer than 240 seconds
(Microsoft's documented limit), and on Azure every upload streams through the
api because presigned uploads are S3-only. An upload that cannot finish in 240
seconds fails. At 10 MB/s that is about 2.4 GB, at 2 MB/s about 480 MB, and
the default `upload_max_size_mb` of 500 assumes a client faster than that.
Size it to the slowest uplink you support, times 240 seconds, with margin. For
larger files, register them by reference from a service or bucket, or upload
from a network inside Azure.

### Staging share and replica size

The staging file share is created with a 100 GiB quota and holds every
upload and conversion in flight. Concurrent large ingests count against that
quota, and a standard SMB share has its own IOPS and throughput limits, which
bound how fast several workers can write. The premium NFS share the Simplified
list mentions is the upgrade.

Everything runs on the Consumption profile, which caps a replica at 4 vCPU and
8 GiB. That limits `api_cpu` (the app's three containers share 4 vCPU) and
`worker_cpu` (4 at most). A single raster larger than the worker's memory
needs a Dedicated workload profile with larger instances. The recipe does not
create one; add a `workload_profile` to the environment and point the worker's
`workload_profile_name` at it.

### Scaling the worker on queue depth

The worker has no ingress, so only a KEDA scaler can move it, and the recipe
does not add one. [`clouds/azure.md`](../../clouds/azure.md#containers) has the
PostgreSQL scaler query to put in a custom scale rule. Keep the worker count
within the connection budget above.

## What is deliberately simplified

Every shortcut is marked with a `# ponytail:` comment naming its ceiling.

- The frontend, api and titiler run in one app. They share a network namespace
  and talk over loopback, so there is no service discovery to run, but they
  cannot scale independently.
- The database administrator is both the migration and the application login.
- The database has no standby unless `db_high_availability` is set, which needs
  a General Purpose SKU and roughly doubles its compute cost.
- Blob storage is LRS: three copies in one datacenter. ZRS or GZRS guards
  against losing a zone or a region.
- titiler reads blobs with the storage account key, which can also write and
  delete. A read-only SAS is the upgrade, at the price of rotating it.
- The cache is one node on a public endpoint, protected by TLS and its access
  key. A private endpoint and high availability are the upgrade.
- Secrets live in Container Apps and in Terraform state rather than in Key
  Vault. Key Vault references are the upgrade when rotation and auditing need
  to happen outside Terraform.
- Staging is an SMB share, so the worker's raster conversions write over the
  network. A premium NFS share is the upgrade when ingest throughput matters.
- The app autoscales only on HTTP concurrency and the worker not at all; see
  "Scaling the worker on queue depth".
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
staging share. The cache, which importing a service that needs a token
requires, adds about $12 a month.

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
follow section 3 of the GeoLens [RUNBOOK](https://github.com/geolens-io/geolens/blob/v1.26.0/RUNBOOK.md)
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

azurerm 5.8 still reports every Container App, job and environment delete as
a failure, `polling after Delete: ... Content-Type "" was not implemented`,
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

Applied again on 2026-10-15 in westus3 with GeoLens 1.24.0 and the defaults,
cache off, and destroyed. The api revision ran Healthy with its readiness
probe on `/health/ready`, and the api logged that probe answering 200 every
ten seconds. `/api/health` reported the database, storage and cache over
HTTPS, `.github/ci/ingest-smoke.sh` ingested a vector and a raster through the
edge and fetched a tile, plain HTTP redirected to HTTPS, and `/api/metrics`
returned 404 at the edge.

Upgraded in place on 2026-10-16 in westus3: the previous recipe applied
GeoLens 1.24.0 with the defaults, cache off, then this one applied 1.25.1 over
it with `cache_enabled = true`, and the stack was destroyed. Before and after
the upgrade `/api/health` reported the database, storage and cache over HTTPS
and `.github/ci/ingest-smoke.sh` ingested a vector and a raster through the
edge and fetched a tile. The upgrade created the Managed Redis instance and
handed its URL to the api and worker, and the migrate job ran 0082 and 0083.
`/api/health` answered 200 throughout, from the 1.24.0 revision until the
1.25.1 one took the traffic. The datasets ingested on 1.24.0 still listed and
served vector and raster tiles. A Sentinel-2 item from Earth Search,
registered by reference through `/api/services/stac/import`, served a raster
tile through the edge, and the api logged titiler's reads on
`/internal/raster-relay/`. The destroy took the four runs Teardown describes.

Upgraded in place on 2026-10-18 in westus3: this recipe applied GeoLens 1.25.1
with the defaults, cache off, then 1.26.0 over it, and the stack was
destroyed. Before and after the upgrade `/api/health` reported the database,
storage and cache over HTTPS and `.github/ci/ingest-smoke.sh` ingested a
vector and a raster through the edge and fetched a tile. The migrate job ran
0084 to 0086. `/api/health` answered 200 throughout, from the 1.25.1 revision
until the 1.26.0 one took the traffic. The datasets ingested on 1.25.1 still
served their collection items and raster tile. An append-only key minted for
the 1.25.1 vector dataset added a feature through the edge (201) and was
refused a read (401). The destroy again took four runs, and neither resource
group nor any soft-deleted workspace or vault remained.

On 2026-10-19 in westus3, the previous recipe applied GeoLens 1.26.0 with the
defaults, and this one then turned on `db_high_availability` over it.
Setting `db_sku_name = "GP_Standard_D2ds_v5"` and `db_high_availability = true`
in one apply failed with `HANotSupportedForBurstableSku` and left the
Burstable server unchanged and serving. In two applies, the SKU change took
seven minutes, about six and a half of them with GeoLens offline while the
server restarted, and the high availability apply took ten, with
`/api/health` answering 200 at every check, ten seconds apart. The standby
came up Healthy in zone 1 with the primary in zone 3. The datasets ingested
on the baseline still served their collection items and raster tile, and
`.github/ci/ingest-smoke.sh` passed before and after. A forced failover
(`az postgres flexible-server restart --failover Forced`) swapped the zones
with about a minute of failed health checks, and a plan afterwards proposed
no changes. The destroy took the four runs Teardown describes, and the sweep
found nothing left.

On 2026-10-20 in westus3, the previous recipe applied GeoLens 1.26.0 with the
defaults (`B_Standard_B1ms`), and this one was applied over it. Both apps and
the database server changed in place: the api and worker took the B1ms pool
settings, the app its 35-second grace period and the server auto-grow.
`/api/health` answered 200 at every check, ten seconds apart, and the next plan
proposed no changes. The baseline datasets still served their collection items
and raster tile, and `.github/ci/ingest-smoke.sh` passed again. Turning on the
cache with three api replicas and two workers, a combination the recipe now
refuses on B1ms because it can exceed the connection limit under load, created
the Managed Redis instance and an HTTP scale rule at 50 concurrent requests,
with health at 200 throughout. Moving to `GP_Standard_D2ds_v5` restarted the
server, and GeoLens was unavailable for about five minutes. Turning on
`zone_redundancy_enabled` replaced the environment, both apps, the migrate job
and the staging mount, and the deletes took the four runs Teardown describes.
The new environment reported zone redundancy, the datasets ingested before the
upgrade still served, and the smoke test passed. A plan of this recipe against
the stack afterwards proposed no changes. The destroy took the four runs
Teardown describes, and the sweep found nothing left.

On 2026-10-22 in westus, the previous recipe applied GeoLens 1.26.0 with the
defaults (`B_Standard_B1ms`), and this one was applied over it. Only the app
changed, in place: the api went from two uvicorn processes with
`UVICORN_MAX_REQUESTS=10000` to one process with no request limit, and its log
showed a single server process. `/api/health` answered 200 at every check, ten
seconds apart, until the new revision took all traffic, and the next plan
proposed no changes. The baseline datasets still served their collection items
and raster tile, and `.github/ci/ingest-smoke.sh` passed again. The server's
`active_connections` metric, which counts Azure's own sessions too, peaked at
26 during the rollout and the smoke test. The destroy took the four runs
Teardown describes, and the sweep found nothing left. That morning westus3
refused to create the B1ms server (`SkuNotAvailable`), although Azure lists the
SKU there.
