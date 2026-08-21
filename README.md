# GeoLens Deployments

Community-maintained Kubernetes packaging for [GeoLens](https://github.com/geolens-io/geolens).

> [!IMPORTANT]
> **Community-maintained / unsupported.** This Helm chart is provided as-is.
> CI installs every change into a throwaway [kind](https://kind.sigs.k8s.io/)
> cluster (install → smoke through the frontend edge → upgrade), but no
> long-lived production cluster is maintained. The **supported** install path
> is Docker Compose — see the
> [GeoLens quickstart](https://docs.getgeolens.com/guides/quickstart/).
> Chart issues and contributions are welcome here.

## Scope

This repo packages the Apache-2.0 **community edition** only — the same software
as [`geolens-io/geolens`](https://github.com/geolens-io/geolens), nothing more.
Deployment artifacts for commercial editions or hosted offerings are maintained
privately and are out of scope here.

## Install

From the hosted Helm repository:

```bash
helm repo add geolens https://geolens-io.github.io/geolens-deployments
helm upgrade --install geolens geolens/geolens [--set ...]
```

or OCI:

```bash
helm upgrade --install geolens oci://ghcr.io/geolens-io/charts/geolens [--set ...]
```

or from a checkout of this repo, replacing `geolens/geolens` with
`helm/geolens` in the commands below. Charts are published by the
`release-charts` workflow whenever a `Chart.yaml` version bump lands on main.

## Helm chart

`helm/geolens` deploys the API, worker, frontend (the app's edge nginx),
Titiler (raster tiles), and an Alembic migration hook Job against an
externally managed PostgreSQL and an optional Redis-compatible cache (the
compose stack ships Valkey). It does **not** install PostgreSQL, object
storage, or the cache — those remain operator-owned services.

Traffic topology: the ingress (or your own edge) sends **all** traffic to the
frontend Service. The frontend image's nginx proxies `/api` and raster-tile
paths to the API Service — stripping the `/api` prefix the backend does not
serve — while blocking the unauthenticated `/api/metrics` endpoint,
rate-limiting anonymous raster traffic, and redacting credentialed paths from
its access log. Don't route around it.

Known limitation behind an ingress controller: the frontend nginx overwrites
forwarded headers (deliberate anti-spoofing when it is the true edge), so the
controller's IP becomes "the client" — the anonymous raster rate limit shares
one bucket across all users and backend logs/rate limits lose the real client
IP. Trusted-proxy support is tracked upstream as
[geolens#581](https://github.com/geolens-io/geolens/issues/581).

> [!NOTE]
> Proxying through the frontend requires frontend image **1.4.9 or newer** —
> older images hardwire a Docker-compose-only upstream and ignore the chart's
> `API_UPSTREAM` env, and no alternative topology works with them. The
> chart's default tags satisfy this; if you pin an older tag, `helm install`
> prints a warning and API traffic will not work.

### Required values

The backend refuses to boot without admin credentials, a JWT secret, and a
database URL. Provide them either inline:

```bash
helm upgrade --install geolens helm/geolens \
  --set secrets.databaseUrlOverride='postgresql+asyncpg://geolens:change-me@postgres.internal:5432/geolens' \
  --set secrets.jwtSecretKey="$(openssl rand -hex 32)" \
  --set secrets.adminUsername='admin' \
  --set secrets.adminPassword='a-strong-unique-password' \
  --set api.publicAppUrl=https://maps.example.com \
  --set api.publicApiUrl=https://maps.example.com/api \
  --set ingress.enabled=true --set ingress.host=maps.example.com
```

or via a pre-created Secret:

```bash
kubectl create secret generic geolens-secrets \
  --from-literal=DATABASE_URL_OVERRIDE='postgresql+asyncpg://geolens:change-me@postgres.internal:5432/geolens' \
  --from-literal=JWT_SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=GEOLENS_ADMIN_USERNAME='admin' \
  --from-literal=GEOLENS_ADMIN_PASSWORD='a-strong-unique-password' \
  --from-literal=POSTGRES_PASSWORD='unused'

helm upgrade --install geolens helm/geolens \
  --set secrets.existingSecret=geolens-secrets \
  --set api.publicAppUrl=https://maps.example.com \
  --set api.publicApiUrl=https://maps.example.com/api
```

Keys the chart reads from an `existingSecret`:

| Key | Required | Purpose |
| --- | --- | --- |
| `DATABASE_URL_OVERRIDE` | yes | async SQLAlchemy DSN of your PostgreSQL |
| `JWT_SECRET_KEY` | yes | JWT signing secret, ≥ 32 chars |
| `GEOLENS_ADMIN_USERNAME` | yes | initial admin login |
| `GEOLENS_ADMIN_PASSWORD` | yes | initial admin password (known-public example values are rejected at boot) |
| `POSTGRES_PASSWORD` | yes | required by backend settings even when `DATABASE_URL_OVERRIDE` carries the real credentials — any placeholder (e.g. `unused`) satisfies it; the chart-managed Secret sets one automatically |
| `TILE_SIGNING_SECRET` | no | signed tile URLs |
| `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` | no | AI features |
| `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | when `storage.backend=s3` and `storage.s3AmbientCredentials` is false | shared object-storage credentials; Titiler uses these only as the compatibility fallback described below. With `storage.s3AmbientCredentials=true` (app images ≥ 1.14.2) both are omitted and the SDKs resolve a role instead — see [Keyless object storage](#keyless-object-storage-irsa--pod-identity) |

The chart sets `ENVIRONMENT=production` by default (API docs hidden, Secure
session cookie). Override with `--set environment=development` only on
throwaway clusters.

Upload sizes: `api.uploadMaxSizeMb` above 500 currently also requires raising
the frontend edge's baked `client_max_body_size` (500m) — tracked upstream as
[geolens#580](https://github.com/geolens-io/geolens/issues/580); until it
lands, larger uploads are rejected at the edge with 413.

### Storage & the shared staging volume

`/app/staging` is scratch space: the api writes uploads there, the worker
reads them to ingest, and Titiler reads rasters under it. By default each pod
gets its own `emptyDir`. Whether that matters depends entirely on the storage
backend:

- **Use `storage.backend=s3`.** This is the one that matters.
  `storage.backend=local` keeps stored rasters and exports inside the staging
  volume, so without persistence they are lost on every pod restart.
- **`staging.persistence` is then optional.** With s3, an upload is written to
  the bucket under a relative key and the worker fetches it from there, so the
  api/worker handoff never crosses a filesystem — measured by ingesting vector
  and raster data across pods with no shared volume at all. Enable it (a
  `ReadWriteMany` PVC, or `staging.persistence.existingClaim`) only if you want
  a shared scratch filesystem for its own sake.
- **On EKS, do not enable it with the defaults.** `ReadWriteMany` is rejected
  outright by the EBS CSI driver (`Volume capabilities not supported`), and an
  empty `staging.persistence.storageClass` renders no `storageClassName`, which
  needs a cluster *default* StorageClass that an eksctl-built cluster does not
  mark — the claim then sits `Pending` forever. RWX on AWS means EFS.

S3-compatible endpoints (MinIO, R2): raster serving resolves assets as
`/vsis3/` paths. The chart derives GDAL's `AWS_S3_ENDPOINT`, `AWS_HTTPS`, and
`AWS_VIRTUAL_HOSTING` settings from `storage.s3Endpoint`, `s3AllowHttp`, and
`s3AddressingStyle`; an explicit `titiler.extraEnv` entry still overrides a
derived value.

#### Keyless object storage (IRSA / Pod Identity)

On EKS you do not need to keep IAM user keys in a Secret at all. Annotate the
chart's ServiceAccount with the role and turn off static keys:

```bash
helm upgrade --install geolens helm/geolens \
  --set storage.backend=s3 \
  --set storage.s3Bucket=geolens \
  --set storage.s3Region=us-east-1 \
  --set storage.s3AmbientCredentials=true \
  --set serviceAccount.create=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::<account>:role/geolens-s3
```

`serviceAccount.create=true` is required here: it defaults to false so that an
upgrade never moves existing workloads off the `default` account, and without
it the annotation is rendered nowhere while this same command removes the
static keys — leaving the pods with no credentials at all.

The api, worker and TiTiler pods then resolve the role themselves — boto3 for
the application, GDAL for TiTiler's `/vsis3/` reads. EKS **Pod Identity** needs
no annotation; associate the role with this ServiceAccount name instead. To
attach a ServiceAccount you manage (eksctl, Terraform), keep
`serviceAccount.create=false` and set `serviceAccount.name`.

Requires app images **≥ 1.14.2**: earlier backends refuse to boot with
`STORAGE_PROVIDER=s3` and no `S3_ACCESS_KEY_ID`, whatever the runtime offers.

> **Migrating an existing install off static keys:** a key already stored in
> the Secret is **not** removed by upgrading to a keyless configuration if that
> Secret was first written by a chart older than 0.4.25 — those releases wrote
> credentials through `stringData`, which the API server folds into `data`, so
> Helm's deletion diff finds nothing to remove. Both boto3 and GDAL prefer a
> static key over an attached role, so the install keeps using the old
> credential while the rendered manifest looks clean. Remove it once, by hand:
>
> ```bash
> kubectl patch secret <release>-secrets --type=json \
>   -p '[{"op":"remove","path":"/data/S3_ACCESS_KEY_ID"},
>        {"op":"remove","path":"/data/S3_SECRET_ACCESS_KEY"}]'
> kubectl rollout restart deploy/<release>-api deploy/<release>-worker deploy/<release>-titiler
> ```
>
> Restarting TiTiler matters: env vars are read at pod start, so a running
> pod keeps the old key until it is replaced.

#### TiTiler read-only S3 credentials

TiTiler never writes objects. Give it a separate principal that can read only
the managed raster prefixes (`rasters/*` and `tenants/*/rasters/*`), store that
principal in an operator-managed Kubernetes Secret, and select it with
`titiler.s3Credentials`. For example, create `geolens-titiler-s3` through your
External Secrets controller or from an operator-protected env file (this keeps
the secret off the Helm command line):

```bash
kubectl create secret generic geolens-titiler-s3 \
  --from-env-file=/secure/path/titiler-s3.env

helm upgrade --install geolens helm/geolens \
  --set secrets.existingSecret=geolens-secrets \
  --set storage.backend=s3 \
  --set storage.s3Bucket=geolens \
  --set titiler.s3Credentials.existingSecret=geolens-titiler-s3 \
  --set titiler.s3Credentials.accessKeyIdKey=AWS_ACCESS_KEY_ID \
  --set titiler.s3Credentials.secretAccessKeyKey=AWS_SECRET_ACCESS_KEY
```

The protected env file contains those two named keys. The chart renders only
the selected Secret references into the TiTiler sidecar; it does not also pass
the shared writer credential. When `titiler.s3Credentials.existingSecret` is
empty, the chart falls back to the main GeoLens Secret and the
`S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` keys, preserving existing installs
while operators migrate.

For MinIO, save this policy as `geolens-titiler-readonly.json`, replacing
`<bucket-name>` with the configured bucket. It grants only `GetObject` under
the single-tenant and tenant-scoped managed-raster layouts:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": [
        "arn:aws:s3:::<bucket-name>/rasters/*",
        "arn:aws:s3:::<bucket-name>/tenants/*/rasters/*"
      ]
    }
  ]
}
```

Create and attach it to a distinct MinIO user, then store that user's generated
credential in the Kubernetes Secret above. Do not put the credential in the
policy file, source control, command arguments, or command output.

```bash
mc admin policy create <alias> geolens-titiler-readonly geolens-titiler-readonly.json
mc admin policy attach <alias> geolens-titiler-readonly --user <titiler-user>
mc admin policy entities <alias> --policy geolens-titiler-readonly
```

### Database requirements

The externally managed PostgreSQL instance must satisfy:

- **PostgreSQL 13+** — `gen_random_uuid()` is used as a column default (core in PG13).
  The migration job fails fast with `GeoLens requires PostgreSQL 13+ (gen_random_uuid)`
  on older servers.
- **pgvector 0.5+** — semantic search uses an HNSW index (migration 0011); older
  pgvector fails with `access method "hnsw" does not exist`.
- **Extensions present**: `postgis`, `pg_trgm`, `vector` (pgvector), `unaccent`.
  On managed services (RDS, Cloud SQL) create them once with a privileged role,
  e.g. `CREATE EXTENSION IF NOT EXISTS vector;`.
- **Schemas and reader role pre-created** — the migrations expect them (the
  hook otherwise fails with `schema "data" does not exist`). Run once with a
  privileged role, where `app_user` is the role from your
  `DATABASE_URL_OVERRIDE` DSN — the `AUTHORIZATION` clause matters on managed
  services (RDS, Cloud SQL): schemas owned by the admin role would leave the
  app user without `USAGE`/`CREATE` and the migration job fails on permission
  errors:

  ```sql
  CREATE SCHEMA IF NOT EXISTS catalog AUTHORIZATION app_user;
  CREATE SCHEMA IF NOT EXISTS data AUTHORIZATION app_user;
  CREATE ROLE geolens_reader NOLOGIN;
  GRANT USAGE ON SCHEMA data TO geolens_reader;
  GRANT SELECT ON ALL TABLES IN SCHEMA data TO geolens_reader;
  ALTER DEFAULT PRIVILEGES FOR ROLE app_user IN SCHEMA data
    GRANT SELECT ON TABLES TO geolens_reader;
  ```

#### Database TLS

Set `database.sslMode` (`disable` | `prefer` | `require` | `verify-full`).
Leaving it empty keeps the application default, `prefer`, which uses encryption
when the server offers it and **silently continues without it when it does
not**.

> Writing `?sslmode=require` into `secrets.databaseUrlOverride` does **not**
> configure TLS. The backend strips that parameter before handing the DSN to
> asyncpg, which has no such option, and derives TLS from `database.sslMode`
> alone. Verified against RDS: with `sslmode=require` in the DSN and the mode
> set to `disable`, the client offered no encryption and only the server's own
> `rds.force_ssl` refused the connection.

`verify-full` additionally needs the provider's CA bundle as a file. Create a
ConfigMap for it and mount it into all three workloads that talk to the
database — the migrate hook included, or the upgrade fails there before any pod
rolls:

```bash
curl -o rds-ca.pem https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem
kubectl create configmap rds-ca --from-file=rds-ca.pem
```

```yaml
database:
  sslMode: verify-full
extraVolumes:
  - name: rds-ca
    configMap:
      name: rds-ca
api:
  extraEnv: [{name: DATABASE_SSL_CA_CERT, value: /etc/ssl/db/rds-ca.pem}]
  extraVolumeMounts: [{name: rds-ca, mountPath: /etc/ssl/db, readOnly: true}]
worker:
  extraEnv: [{name: DATABASE_SSL_CA_CERT, value: /etc/ssl/db/rds-ca.pem}]
  extraVolumeMounts: [{name: rds-ca, mountPath: /etc/ssl/db, readOnly: true}]
migrate:
  # extraEnv is not repeated here: the migrate Job already renders
  # api.extraEnv. Setting the same name in both is safe (the migrate value
  # wins, and the chart drops the duplicate), but there is nothing to gain.
  # The MOUNT is not shared, so that one does have to be repeated.
  extraVolumeMounts: [{name: rds-ca, mountPath: /etc/ssl/db, readOnly: true}]
```

`verify-full` needs app images **≥ 1.14.2** on any deployment that ingests
vector data: earlier builds passed the TLS mode to `ogr2ogr` without the CA
path, so every vector ingest failed inside libpq with `root certificate file
... does not exist` while the API itself stayed healthy.

### Backups

The chart ships no backup workload. The Docker Compose stack's `backup`
service (scheduled `pg_dump`, local retention, optional offsite S3 upload)
is Compose-only: it dumps the bundled `db` container, and this chart does
not install PostgreSQL. On Kubernetes, database recovery belongs to your
externally managed PostgreSQL — use its native backup/PITR. If you enable
`staging.persistence`, cover that PVC with your volume-snapshot tooling;
uploaded source files live there. Restore procedures are in the main repo's
[RUNBOOK.md](https://github.com/geolens-io/geolens/blob/main/RUNBOOK.md)
(section 3, managed / external Postgres mode).

### Migrations & upgrades

Migrations run in a `pre-install,pre-upgrade` hook Job, so new pods only start
against a migrated schema and repeated `helm upgrade`s never trip Kubernetes'
immutable-Job rule. The api pods skip their own boot-time migration while the
hook is enabled (`migrate.enabled=true`, the default). Extra env for the hook
(e.g. `DATABASE_SSL_MODE`) follows `api.extraEnv` and `migrate.extraEnv`.

To upgrade GeoLens: bump the three `ghcr.io/geolens-io/*` image tags (they
track GeoLens releases; a weekly CI check flags drift) and `helm upgrade`.

### Render locally

```bash
helm template geolens helm/geolens \
  --set secrets.databaseUrlOverride='postgresql+asyncpg://geolens:change-me@postgres/geolens' \
  --set secrets.jwtSecretKey="$(openssl rand -hex 32)" \
  --set secrets.adminUsername=admin \
  --set secrets.adminPassword='a-strong-unique-password'
```

## License

Apache-2.0 — same as GeoLens. See [LICENSE](LICENSE).
