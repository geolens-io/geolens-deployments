# GeoLens Deployments

Community-maintained Kubernetes packaging for [GeoLens](https://github.com/geolens-io/geolens).

> [!IMPORTANT]
> **Community-maintained / unsupported.** This Helm chart is provided as-is and is
> not actively tested against a live cluster. The **supported** install path is
> Docker Compose — see the [GeoLens quickstart](https://docs.getgeolens.com/guides/quickstart/).
> Chart issues and contributions are welcome here.

## Helm chart

`helm/geolens` deploys the API, worker, frontend, and a one-shot migration job
against an externally managed PostgreSQL and an optional Redis. It does **not**
install PostgreSQL, S3, or Redis — those remain operator-owned services.

Point `*.image.tag` in `values.yaml` at a published GeoLens image version
(`ghcr.io/geolens-io/geolens-api`, `-worker`, `-frontend`).

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

### Render locally

```bash
helm template geolens helm/geolens \
  --set secrets.databaseUrlOverride='postgresql+asyncpg://geolens:change-me@postgres/geolens' \
  --set secrets.jwtSecretKey='change-me'
```

### Install with an existing Kubernetes secret

```bash
helm upgrade --install geolens helm/geolens \
  --set secrets.existingSecret=geolens-secrets \
  --set api.publicAppUrl=https://maps.example.com \
  --set api.publicApiUrl=https://maps.example.com/api
```

## License

Apache-2.0 — same as GeoLens. See [LICENSE](LICENSE).
