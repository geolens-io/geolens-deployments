# Terraform recipes

Each directory is a self-contained root module that runs the published
[GeoLens](https://github.com/geolens-io/geolens) images on one cloud's managed
services. No registry modules, no shared wrapper: copy the directory, set the
variables, apply.

| Recipe | Status | Manual path |
| --- | --- | --- |
| [`aws-ecs-fargate`](aws-ecs-fargate/) | Validated on a real account (2026-09-07, GeoLens 1.18.1). ECS Fargate, RDS PostgreSQL 17, S3, ElastiCache Valkey, ALB. | [`clouds/aws.md`](../clouds/aws.md) |
| Azure | Planned, not started: [#41](https://github.com/geolens-io/geolens-deployments/issues/41). | [`clouds/azure.md`](../clouds/azure.md) |
| Google Cloud | Planned, not started: [#42](https://github.com/geolens-io/geolens-deployments/issues/42). | [`clouds/google-cloud.md`](../clouds/google-cloud.md) |
| DigitalOcean | Planned, not started: [#43](https://github.com/geolens-io/geolens-deployments/issues/43). | [`clouds/digitalocean.md`](../clouds/digitalocean.md) |

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

[`clouds/`](../clouds/) covers the managed services themselves, one page per
cloud, with the environment variables each one needs. What is left here is the
container topology each runtime forces, which is a recipe decision rather than
a provisioning one.

Azure: Container Apps supports several containers in one app, so the loopback
layout from the AWS recipe carries over, with the worker as a second app.

Google Cloud: Cloud Run multi-container services cover the frontend, api and
titiler. The worker is a long-running process, so it belongs in its own
service with CPU always allocated and minimum instances 1, or on a small GCE
VM. Reaching a private Cloud Run service needs a Google-signed ID token that
neither the nginx proxy hop nor the api's titiler client mints.

DigitalOcean: App Platform has no sidecar concept, so the api and titiler
become separate components with internal routing and `TITILER_BASE_URL`
pointed at the titiler component.

A recipe landing is the moment to correct the cloud page beside it, since the
recipe is what proves the prose.
