# Azure

PostgreSQL Flexible Server, Blob Storage, and optionally Azure Cache for
Redis, with the containers on Container Apps.

There is no Terraform recipe yet;
[#41](https://github.com/geolens-io/geolens-deployments/issues/41) tracks one.
Azure Blob Storage is a first-class storage backend in the application, so the
manual path below is a supported deployment, not a workaround.

Nothing here has been applied against a real subscription. Treat it as a
starting point and open an issue when a step is wrong.

## Database: PostgreSQL Flexible Server

Create a Flexible Server on PostgreSQL 15 or newer.

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
`STORAGE_PROVIDER=azure` the browser posts files to the api and the api writes
them to the container. Large uploads therefore traverse the api, and any body
size limit on the ingress applies to them.

## Cache: Azure Cache for Redis

Optional, and only worth provisioning for more than one API instance. Create
an instance reachable from the Container Apps environment and set `REDIS_URL`.
With it unset the application caches in process memory, which is correct for a
single instance and wrong for several.

## Containers

Container Apps supports several containers in one app sharing a network
namespace, so the loopback layout from the AWS recipe carries over: the
frontend, the api and titiler in one app, the worker as a second app with no
ingress.

Titiler defaults to port 8000, which the api already holds. Override its
command to move it, as
[`terraform/aws-ecs-fargate`](../terraform/aws-ecs-fargate/) does, then point
`TITILER_BASE_URL` at the new port. Set `API_UPSTREAM` on the frontend to
`http://127.0.0.1:8000`. Both variables default to Compose service names that
resolve to nothing on Container Apps, and leaving them alone gives you an
nginx upstream error on `/api` and no raster tiles.

Put external ingress on the frontend only, on port 8080. It is the application
edge: it proxies `/api`, maps `/raster-tiles`, blocks unauthenticated
`/api/metrics`, and rate-limits anonymous raster traffic.

## HTTPS

Container Apps terminates TLS on its own `*.azurecontainerapps.io` hostname
and provisions a managed certificate for a custom domain you bind to the app.
Set `PUBLIC_APP_URL` and `PUBLIC_API_URL` to that public hostname afterwards,
or OGC self-links and OAuth redirects point at the wrong host.

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

REDIS_URL=redis://<cache>.redis.cache.windows.net:6379/0
```

On the Titiler container instead:

```bash
AZURE_STORAGE_ACCOUNT=<account>
AZURE_STORAGE_ACCESS_KEY=<account-key>
```

## When it goes wrong

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
