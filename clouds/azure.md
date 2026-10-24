# Azure

PostgreSQL Flexible Server, Blob Storage, and optionally Azure Managed Redis,
with the containers on Container Apps.

[`terraform/azure-container-apps`](../terraform/azure-container-apps/)
automates everything on this page and was validated against a real
subscription. Azure Blob Storage is a first-class storage backend in the
application, so the manual path below is a supported deployment, not a
workaround.

Many subscriptions cannot create a Flexible Server in the busiest regions
(eastus, eastus2 and westus2 among them), and Container Apps turns new
environments away in regions short of capacity. Check with
`az postgres flexible-server list-skus --location <region>` before you
provision anything.

## Database: PostgreSQL Flexible Server

Create a Flexible Server on PostgreSQL 15 or newer, naming the database and the
administrator login as you go. A server carries a `postgres` database and
whatever administrator you asked for, so the `geolens` database in the DSN
below has to be created explicitly, either here or with
`az postgres flexible-server db create` afterwards.

```bash
az postgres flexible-server create \
  --resource-group <resource-group> --name <server> \
  --version 15 --database-name geolens \
  --admin-user geolens --admin-password "$DB_PASSWORD"
```

For a standby, add `--high-availability ZoneRedundant` on a General Purpose or
Memory Optimized tier, such as `--tier GeneralPurpose --sku-name
Standard_D2ds_v5`. Burstable servers can't run one, and it roughly doubles the
compute cost. The recipe sets it with `db_high_availability = true`.

**Allow-list the extensions before anything else.** Flexible Server refuses
`CREATE EXTENSION` for any extension missing from the `azure.extensions`
server parameter, and no amount of privilege on the connecting role changes
that. This is the one prerequisite that has no equivalent on the other three
clouds, and skipping it makes the bootstrap SQL fail in a way that reads like
a permissions problem.

```bash
az postgres flexible-server parameter set \
  --resource-group <resource-group> \
  --server-name <server> \
  --name azure.extensions \
  --value "POSTGIS,VECTOR,PG_TRGM,UNACCENT"
```

The portal offers the same list under Settings, Parameters. Setting the
parameter starts a deployment; wait for it to finish before connecting.

With the four extensions allow-listed, connect with `psql` and run the
bootstrap SQL from the
[cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/),
which creates the extensions, the `catalog` and `data` schemas, and the
`geolens_reader` role.

The administrator is not a superuser, and GeoLens 1.20.0's migrations hand
the tenant boundary functions to the `geolens_tenant_provisioner` role, which
PostgreSQL allows only when that role may `CREATE` in `catalog` and the caller
may `SET ROLE` to it. Lend both before `alembic upgrade heads` and take them
back afterwards, as steps 2b and 2g of the GeoLens RUNBOOK describe. On a fresh
database the role does not exist yet, so create it first with the attributes
migration 0019 checks for (`NOLOGIN NOSUPERUSER NOCREATEDB CREATEROLE NOINHERIT
NOREPLICATION NOBYPASSRLS`). The recipe's `migrate.py` does all three.

Flexible Server enforces TLS, so set `DATABASE_SSL_MODE=require`. Networking
is chosen at creation and cannot be changed afterwards: either public access
with a firewall rule covering the Container Apps environment's outbound
addresses, or private access on the same virtual network.

## Storage: Blob Storage

The backend talks to Blob Storage through the Azure SDK, not through an
S3 shim, so none of the `S3_*` variables apply. Create a storage account and
a container, then set `STORAGE_PROVIDER=azure`.

`AZURE_STORAGE_CONTAINER` is required. For credentials, pick one of two
shapes and the application refuses to boot without either:

- `AZURE_STORAGE_CONNECTION_STRING`, the full connection string. It wins when
  both are set.
- `AZURE_STORAGE_ACCOUNT_URL` (`https://<account>.blob.core.windows.net`) plus
  `AZURE_STORAGE_ACCOUNT_KEY`, the account access key.

**Managed identity does not work yet.** `azure-identity` is deliberately not a
dependency, so an account URL with no key authenticates as nobody and every
object read fails at runtime rather than at boot. Use a key or a connection
string, and keep it in Key Vault.

Titiler reads rasters through GDAL's `/vsiaz/` driver, which reads its own
environment variables rather than the application's. Give the Titiler
container `AZURE_STORAGE_CONNECTION_STRING`, or the pair
`AZURE_STORAGE_ACCOUNT` (the account name alone, not the URL) and
`AZURE_STORAGE_ACCESS_KEY`. That last name is GDAL's, and it holds the same
value as the application's `AZURE_STORAGE_ACCOUNT_KEY`. The bundled Compose
file translates it at the container boundary; on Container Apps you do it in
the app definition.

No CORS policy is needed. Presigned uploads are an S3-only path, so with
`STORAGE_PROVIDER=azure` the browser posts files to the api. Large uploads
therefore traverse the api, and any body size limit on the ingress applies to
them.

**The api and the worker need a shared `/app/staging`.** Only
`STORAGE_PROVIDER=s3` hands an upload to the worker through the bucket. With
`azure` the api writes it to `/app/staging` and queues the local path, and a
worker that cannot see that path fails the ingest at "validating" with a
`BlobNotFound`. On Container Apps, create an Azure Files share, register it
with the environment, and mount it at `/app/staging` in both apps with the
mount options `uid=1001,gid=1001`. Without them the share presents every file
as owned by root, and raster conversion fails with `Operation not permitted`
when it copies file times.

Since no browser ever talks to Blob Storage directly, the storage account can
refuse everything but the Container Apps subnet: add a `Microsoft.Storage`
service endpoint to that subnet and a network rule that allows it and denies
the rest. Set the trusted-services exception to `None` as well
(`az storage account update --bypass None`). It defaults to `AzureServices`,
which lets Microsoft's trusted services past the rule, and nothing here needs
it.

## Cache

From GeoLens 1.23.0 the cache is required to import, re-upload or refresh a
service that needs a token, even on a single instance: with `REDIS_URL` unset,
those requests answer 503 `credential_store_unavailable`. It is also required
for more than one API instance. Otherwise the application caches in process
memory, which is correct for a single instance.

Azure Managed Redis is the service to create for a new deployment. Azure Cache
for Redis is on a retirement path, and its Basic, Standard and Premium tiers
are already unavailable to subscriptions that have never used it, so check what
your subscription can actually create before planning around either.

Whichever you land on, expect TLS and key authentication rather than an open
port: the URL is `rediss://` with the access key as the password, on 6380 for a
legacy Cache for Redis instance and on the port the portal shows for a Managed
Redis one. A plain `redis://` on 6379 will not connect. Take the hostname and
port from the resource rather than assembling them.

Percent-encode the access key before putting it in the URL. These keys are
base64 and can contain `/`, which a URL parser reads as the start of a path
rather than as part of the password, so an otherwise valid cache fails to
connect. `/` becomes `%2F`, and `+` becomes `%2B`.

## Containers

Container Apps supports several containers in one app sharing a network
namespace, so the loopback layout from the AWS recipe carries over: the
frontend, the api and titiler in one app, the worker as a second app with no
ingress.

Give the worker app a minimum of one replica. Container Apps scales to zero by
default, and an app with no ingress has no HTTP trigger to scale it back up, so
a worker left on the default sits at zero replicas and queued imports are never
picked up. Either pin `--min-replicas 1` or attach a KEDA PostgreSQL scaler
on the job queue, for example with the query
`SELECT count(*) FROM catalog.procrastinate_jobs WHERE status = 'todo'`, a
`targetQueryValue` of about 5 and the database password as a secret. The app
tolerates several workers; keep them within the connection budget below.

**Scaling the app.** Add an HTTP scale rule (`concurrentRequests` about 50)
and a maximum above the minimum, with the shared cache; the recipe's
[Scaling](../terraform/azure-container-apps/README.md#scaling) section covers
the grace period, replica size limits and zone redundancy.

**Request timeout.** Container Apps ingress ends a request after 240 seconds,
so an upload through the api that takes longer fails; see
[Uploads and the ingress timeout](../terraform/azure-container-apps/README.md#uploads-and-the-ingress-timeout).

**Database connections.** B1ms allows only 35 usable connections; the formula
is in [Database connections](README.md#database-connections) and the numbers in
the [recipe README](../terraform/azure-container-apps/README.md#database-connections).
On B1ms run one api process, the image default: leave `UVICORN_WORKERS` at 1
and `UVICORN_MAX_REQUESTS` unset, because a single process that reaches the
request limit exits and takes the container with it. Scale the database tier rather than using the built-in PgBouncer, which GeoLens
can't use yet: its job queue sets `search_path` through the `options` startup
parameter, and PgBouncer rejects that
([geolens#3213](https://github.com/geolens-io/geolens/issues/3213)).

Titiler defaults to port 8000, which the api already holds. Override its
command to move it, as
[`terraform/aws-ecs-fargate`](../terraform/aws-ecs-fargate/) does, then point
`TITILER_BASE_URL` at the new port. Set `API_UPSTREAM` on the frontend to
`http://127.0.0.1:8000`. Both variables default to Compose service names that
resolve to nothing on Container Apps, and leaving them alone gives you an
nginx upstream error on `/api` and no raster tiles.

Titiler also reads remote (STAC) rasters through an internal route on the api.
Set `REMOTE_RASTER_RELAY_BASE_URL` on the api and worker to
`http://127.0.0.1:8000`, and keep ingress on the frontend edge, which refuses
`/api/internal/`.

Put external ingress on the frontend only, on port 8080. It is the application
edge: it proxies `/api`, maps `/raster-tiles`, blocks unauthenticated
`/api/metrics`, and rate-limits anonymous raster traffic.

Probe the api container on port 8000. Use `/health/live` for startup and
liveness, and `/health/ready` for readiness on GeoLens 1.21.0 and later: it
answers 503 while the api cannot query the database, so a revision with a wrong
connection string never takes over from the one serving. Older images answer
404 on `/health/ready`, so keep `/health/live` for readiness there. Don't use
`/health` for any of them, since an object store or cache blip would fail every
replica at once.

Set `TRUSTED_PROXY_CIDRS` on the frontend to the ranges a workload profiles
environment reserves for itself,
`100.100.0.0/17,100.100.128.0/19,100.100.160.0/19,100.100.192.0/19`. The
ingress proxies connect from there, not from your virtual network, and without
it every visitor shares one rate-limit bucket and logs as one address.

Upgrading to 1.22.0 from an earlier release: file replacements use a new
worker task. A replacement submitted while a worker from the previous release
is still running can fail as an unknown task. Nothing is published when that
happens, so submit the replacement again once every worker runs 1.22.0.

Upgrading to 1.23.0: importing, re-uploading or refreshing a service that
needs a token now requires a cache the api and worker share. With `REDIS_URL` unset
those requests answer 503 `credential_store_unavailable`. Services without a
token are unaffected.

Upgrading to 1.25 from an earlier release (1.25.1 is the first with api and
worker images): migration 0083 builds its indexes on `ingest_jobs` and
`records` with `CREATE INDEX CONCURRENTLY`, which waits for open
transactions to finish and takes longer on a large catalog. Give the
migration time, and leave the apps on the previous release until it
succeeds. If it stops partway, run it again; 0083 drops and rebuilds the
invalid index an interrupted build leaves behind. Outbound TLS from the AI
providers and the OAuth client now checks the operating system trust store
instead of certifi: behind a private certificate authority, mount a bundle
holding the system CAs plus yours on the api and worker and point
`SSL_CERT_FILE` at it. The frontend's default CSP no longer allows
Cloudflare's Web Analytics beacon; on a Cloudflare-proxied install with Web
Analytics on, set `CSP_SCRIPT_SRC_EXTRA=https://static.cloudflareinsights.com`
on the frontend, the host rather than the `beacon.min.js` path. After 10
failed password sign-ins within an hour, an account answers 429 to browsers
it doesn't know. To let an admin back in, run
`/app/.venv/bin/python -m scripts.trust_login_device <username>` in the api
container through `az containerapp exec --container api`; it prints a link
that works once, within 10 minutes.

Upgrading to 1.26.0: migrations 0084 to 0086 are additive. 0085 waits at most
5 seconds for its lock on `catalog.datasets` instead of queueing behind other
writes, so on a busy catalog the migration can fail with a lock timeout.
Leave the apps on the previous release and run the migrate job again before
rolling them onto 1.26.0.

Upgrading to 1.27.1: from 1.26, upgrade straight to 1.27.1 rather than 1.27.0.
1.27.0's migration 0088 drops columns that 1.26 reads, so 1.26 replicas still
serving during the rollout fail dataset requests and jobs until they are
replaced; 1.27.1 keeps those columns. Migrations 0087 to 0094 run. 0088 and
0091 to 0094 wait at most 5 seconds for their locks instead of queueing behind
other writes, so on a busy catalog the migration can fail with a lock timeout.
Leave the apps on the previous release and run the migrate job again before
rolling them onto 1.27.1. 0088 moves each dataset's kept previous version onto
its version row, so rolling back below 1.27 refuses while any dataset keeps
more than one previous version. From 1.27.0, no migration runs.

## HTTPS

Container Apps terminates TLS on its own `*.azurecontainerapps.io` hostname
and provisions a managed certificate for a custom domain you bind to the app.
Afterwards, `PUBLIC_APP_URL` is the public hostname and
`PUBLIC_API_URL` is that hostname plus `/api`. Both feed OGC self-links, OAuth
redirects and generated distribution URLs, so dropping the suffix points
API links at the frontend root.

## Environment delta

Everything else stays as the
[cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/)
has it.

```bash
DATABASE_URL_OVERRIDE=postgresql://geolens:<password>@<server>.postgres.database.azure.com:5432/geolens
DATABASE_SSL_MODE=require

STORAGE_PROVIDER=azure
AZURE_STORAGE_CONTAINER=geolens-uploads
# Either the connection string on its own:
AZURE_STORAGE_CONNECTION_STRING=<connection-string>
# or the account URL plus its key:
# AZURE_STORAGE_ACCOUNT_URL=https://<account>.blob.core.windows.net
# AZURE_STORAGE_ACCOUNT_KEY=<account-key>

# Host and port come from the cache resource; 6380 is the legacy default.
REDIS_URL=rediss://:<percent-encoded-access-key>@<cache-hostname>:6380/0
```

On the Titiler container instead:

```bash
AZURE_STORAGE_ACCOUNT=<account>
AZURE_STORAGE_ACCESS_KEY=<account-key>
```

On the frontend:

```bash
API_UPSTREAM=http://127.0.0.1:8000
TRUSTED_PROXY_CIDRS=100.100.0.0/17,100.100.128.0/19,100.100.160.0/19,100.100.192.0/19
```

## When it goes wrong

**`psql` reports that the `geolens` database does not exist.** The server was
created without `--database-name`. Add it with
`az postgres flexible-server db create`.

**`CREATE EXTENSION` is refused and the message mentions an allow list.** The
extension is not in `azure.extensions`. Add it, wait for the parameter
deployment, then rerun the bootstrap SQL. Granting the connecting role more
privilege does nothing.

**The api boots but every file operation fails.** An account URL was set with
no account key, so the SDK is authenticating anonymously. Configuration
validation only checks that one of the two credential shapes is present, so
this surfaces at first use rather than at startup.

**Raster tiles fail while vector data works.** Titiler is missing its own
`AZURE_STORAGE_*` variables. It does not inherit the api's.

**Imports stay queued and nothing processes them.** The worker app scaled to
zero and has nothing to wake it.

**Every import fails at "validating" with `BlobNotFound`.** The worker cannot
see the api's `/app/staging`. Mount one share there in both apps.

**Vector imports work but rasters fail at "cog_convert" with `Operation not
permitted`.** The staging share is mounted without `uid=1001,gid=1001`.

**The first migration fails with `permission denied for schema catalog`.** The
administrator is not a superuser; lend the provisioner role its two privileges
first, as described under the database.

**Every request logs the same `100.100.x.x` client.** `TRUSTED_PROXY_CIDRS` is
missing or names the virtual network instead of the environment's reserved
ranges.
