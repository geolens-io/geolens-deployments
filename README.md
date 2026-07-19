# GeoLens Deployments

Community-maintained Kubernetes packaging for [GeoLens](https://github.com/geolens-io/geolens).

> [!IMPORTANT]
> **Community-maintained / unsupported.** This Helm chart is provided as-is and is
> not actively tested against a live cluster. The **supported** install path is
> Docker Compose — see the [GeoLens quickstart](https://docs.getgeolens.com/guides/quickstart/).
> Chart issues and contributions are welcome here.

## Scope

This repo packages the Apache-2.0 **community edition** only — the same software
as [`geolens-io/geolens`](https://github.com/geolens-io/geolens), nothing more.
Deployment artifacts for commercial editions or hosted offerings are maintained
privately and are out of scope here.

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
| `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | when `storage.backend=s3` | object storage credentials — the backend hard-requires them for s3 (no ambient/IRSA fallback); also handed to Titiler as `AWS_*` |

The chart sets `ENVIRONMENT=production` by default (API docs hidden, Secure
session cookie). Override with `--set environment=development` only on
throwaway clusters.

Upload sizes: `api.uploadMaxSizeMb` above 500 currently also requires raising
the frontend edge's baked `client_max_body_size` (500m) — tracked upstream as
[geolens#580](https://github.com/geolens-io/geolens/issues/580); until it
lands, larger uploads are rejected at the edge with 413.

### Storage & the shared staging volume

`/app/staging` is a shared handoff path: the api writes uploads there, the
worker reads them to ingest, and Titiler reads rasters under it. By default
each pod gets its own `emptyDir`, which breaks that handoff across pods — fine
for a quick render, not for real use. For a working deployment:

- **Enable `staging.persistence`** (a `ReadWriteMany` PVC, or point
  `staging.persistence.existingClaim` at one), **and**
- **use `storage.backend=s3`** for durable artifact storage.
  `storage.backend=local` keeps stored rasters/exports inside the staging
  volume, so without persistence they are lost on every pod restart.

S3-compatible endpoints (MinIO, R2): raster serving resolves assets as
`/vsis3/` paths, and upstream GeoLens does not yet plumb a custom endpoint
through to GDAL/Titiler (its compose stack has the same gap). Until that
lands upstream, pass the GDAL env yourself via `titiler.extraEnv` — see the
example in `values.yaml`.

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
