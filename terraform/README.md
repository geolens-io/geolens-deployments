# Terraform recipes

Each directory is a self-contained root module that runs the published
[GeoLens](https://github.com/geolens-io/geolens) images on one cloud's managed
services. No registry modules, no shared wrapper: copy the directory, set the
variables, apply.

| Recipe | Status |
| --- | --- |
| [`aws-ecs-fargate`](aws-ecs-fargate/) | Validated on a real account (2026-09-07, GeoLens 1.18.1). ECS Fargate, RDS PostgreSQL 17, S3, ElastiCache Valkey, ALB. |
| Azure | Planned, not started. |
| Google Cloud | Planned, not started. |
| DigitalOcean | Planned, not started. |

## What a recipe has to provide

The application is the same everywhere. Each recipe maps five pieces onto a
cloud:

1. A PostgreSQL 13+ instance with PostGIS, pgvector 0.5+, pg_trgm and
   unaccent, plus a one-shot job that creates the `catalog` and `data` schemas
   and the `geolens_reader` role before the first `alembic upgrade heads`.
2. Object storage. The backend speaks S3 natively and Azure Blob through
   `STORAGE_PROVIDER=azure`. S3-compatible stores work by setting
   `S3_ENDPOINT`.
3. An optional Redis-compatible cache reachable as `REDIS_URL`.
4. Four containers: the frontend edge, the api, the worker, and titiler. The
   frontend must be the only public target, and when the api and titiler share
   a network namespace titiler has to move off port 8000.
5. Somewhere to keep the JWT secret, admin password and database DSN out of
   the task definition.

## Notes for the planned recipes

These are the shapes worth trying first, with the things already known to
matter.

Azure: Container Apps for the four containers, PostgreSQL Flexible Server (it
ships PostGIS, pgvector, pg_trgm and unaccent as allow-listed extensions), Blob
Storage through the backend's native Azure provider and titiler's `/vsiaz/`
reads, Azure Cache for Redis. Container Apps supports sidecars in one app, so
the loopback layout from the AWS recipe carries over.

Google Cloud: Cloud Run for the api and frontend, Cloud SQL for PostgreSQL
(PostGIS and pgvector are supported flags), a GCS bucket reached through the
S3-compatible XML API with HMAC keys and `S3_ENDPOINT=https://storage.googleapis.com`,
Memorystore for Valkey. The worker is a long-running process, so it belongs in
a Cloud Run service with CPU always allocated and min instances 1, or on a
small GCE VM. Cloud Run multi-container services cover the frontend, api and
titiler sidecar layout.

DigitalOcean: App Platform for the containers, Managed PostgreSQL (PostGIS and
pgvector are available; check the version supports pgvector 0.5+), Spaces with
`S3_ENDPOINT=https://<region>.digitaloceanspaces.com`, optional Managed Valkey.
App Platform has no sidecar concept, so the api and titiler become separate
components with internal routing and `TITILER_BASE_URL` pointed at the
titiler component.

The docs site's
[cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/)
already documents the environment variables for each provider's managed
database, bucket and cache; the recipes should reuse those values rather than
invent new ones.
