# Cloud guidance

Provisioning notes for the managed services GeoLens runs on, one page per
cloud, kept next to the Terraform recipes that automate the same services.

| Cloud | Managed services | Recipe |
| --- | --- | --- |
| [AWS](aws.md) | RDS for PostgreSQL, S3, ElastiCache | [`terraform/aws-ecs-fargate`](../terraform/aws-ecs-fargate/) |
| [Azure](azure.md) | PostgreSQL Flexible Server, Blob Storage, Azure Managed Redis | [`terraform/azure-container-apps`](../terraform/azure-container-apps/) |
| [Google Cloud](google-cloud.md) | Cloud SQL, Cloud Storage, Memorystore | Planned: [#42](https://github.com/geolens-io/geolens-deployments/issues/42) |
| [DigitalOcean](digitalocean.md) | Managed PostgreSQL, Spaces, Managed Valkey | Planned: [#43](https://github.com/geolens-io/geolens-deployments/issues/43) |

Each page covers only what its cloud does differently. The parts that are the
same everywhere live in two other places:

- [`terraform/README.md`](../terraform/README.md) states the five pieces any
  deployment has to provide, whether a recipe or a person provisions them.
- The docs site's
  [cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/)
  holds the environment contract, the database bootstrap SQL, when migrations
  run, the health and metrics endpoints, and the troubleshooting that is not
  specific to one cloud.

Read the guide first, pick a cloud, then come back here.

## Reading a page

Every page follows the same order: database, object storage, cache, then how
the containers reach each other on that cloud's runtime, then the environment
variables that differ from the neutral set. The last section is the one to
diff against the guide; everything else in `.env` stays as the guide has it.

The database password goes into a URL, so percent-encode it or generate one
without URI delimiters. A `#`, `?`, `@`, `/` or `%` in the raw password changes
where the parser thinks the host begins, and the API, worker and migration all
fail to connect. The recipes sidestep this by generating a password with no
special characters at all, which is the easier habit.

Every `DATABASE_URL_OVERRIDE` here uses the plain `postgresql://` form. The
backend rewrites it to `postgresql+asyncpg://` and strips any `sslmode`
parameter, since `DATABASE_SSL_MODE` owns that setting. An explicit
`postgresql+asyncpg://`, which is what the recipes emit, is accepted
unchanged.

## Which path

A cloud page describes provisioning by hand, through the console or the CLI.
Two other paths exist and are usually less work:

- The [Helm chart](../helm/geolens/) if you already run Kubernetes. The
  managed database, bucket and cache still have to exist, so the database and
  storage sections here still apply.
- A [Terraform recipe](../terraform/) where one exists for your cloud. The
  recipe provisions the same services the page describes, so read the page for
  what the recipe is doing and skip the console steps.

## Database connections

GeoLens opens its own connection pools, so the number of database connections
grows with every replica and every uvicorn worker. Add them up before choosing
replica counts, because a managed database caps `max_connections` by memory
size and refuses the rest. The defaults below are from the application's
settings (`DB_POOL_SIZE`, `DB_MAX_OVERFLOW`, `TILE_POOL_MAX_SIZE`); the
[Configuration Reference](https://docs.getgeolens.com/guides/quickstart/configuration/#connection-pool-tuning)
covers each one.

One uvicorn worker process in the api holds, at most:

| Pool | Setting | Default |
| --- | --- | --- |
| SQLAlchemy engine | `DB_POOL_SIZE` plus `DB_MAX_OVERFLOW` | 10 + 3 = 13 |
| Tile queries (asyncpg) | `TILE_POOL_MAX_SIZE` | 10 |
| Procrastinate connector, which defers jobs | fixed | 3 |
| Readiness probes | fixed | 1 |
| Total | | 27 |

Each api replica runs `UVICORN_WORKERS` such processes (default 1), and every
one has its own pools. The background worker (the `worker` service, not a
uvicorn process) holds the engine pool (13), the connector pool (3), one
separate connection that listens for new jobs (`LISTEN`) and one for readiness
probes, 18 in all. GeoLens 1.26.0 holds no readiness connection, so it uses one
fewer in each process. The migrate job adds a few connections while it runs.

```text
connections = api_replicas x UVICORN_WORKERS x 27
            + worker_replicas x 18
            + migrate job (a few, while it runs)
```

For example, 2 api replicas with 2 uvicorn workers each plus 1 worker is
`2 x 2 x 27 + 18 = 126` connections at the ceiling. Pools open connections on
demand, so an idle install sits far lower, but a burst of tile requests can
reach the ceiling. During a rolling deploy old and new replicas overlap, so
budget for both. Keep the total under about 80 percent of the database's
`max_connections`, and leave room for your own admin sessions.

To shrink the number, lower `DB_POOL_SIZE`, `DB_MAX_OVERFLOW` and
`TILE_POOL_MAX_SIZE`, or move to a database tier with more connections. The
tile pool also caps concurrent uncached tile renders per process, so cutting it
trades connections for tile throughput. The sandbox query limit follows the
engine pool: it admits `(DB_POOL_SIZE + DB_MAX_OVERFLOW) / 3` at once.

A transaction-mode pooler is not an option yet. The job queue sets its
`search_path` through the `options` startup parameter, which PgBouncer rejects,
so the api and worker fail to start behind PgBouncer-based poolers: Azure's
built-in PgBouncer, Cloud SQL Managed Connection Pooling and DigitalOcean
connection pools. RDS Proxy has not been tested.
[geolens#3213](https://github.com/geolens-io/geolens/issues/3213) tracks
the fix.

## High availability

The application tier scales out; the database does not, so high availability
means several API and frontend replicas against a managed PostgreSQL with
automatic failover, shared object storage and one cache. Every path needs the
same four things:

- **Shared object storage.** Not pod-local disk. With the Helm chart,
  `storage.backend: local` without `staging.persistence` gives each pod its own
  copy of every file (see the comments above `storage.backend` in
  [`values.yaml`](../helm/geolens/values.yaml)). Use S3 or a compatible
  bucket, or Azure Blob with a ReadWriteMany staging claim.
- **One shared cache, with failover.** Point every api and worker at the same
  Valkey or Redis with `REDIS_URL`. Without it, rate limits count per replica,
  caches are per process, and importing, re-uploading or refreshing a service
  that needs a token answers 503 `credential_store_unavailable`. Run the cache
  with a replica and automatic failover too, or a cache outage stops those
  paths while the app and database stay up.
- **One writable database endpoint.** GeoLens connects to a single primary and
  has no read-replica support. A standby is for failover only.
- **At least one worker, ideally two.** The worker can run more than one
  replica (`worker.replicas` in Helm). Keep at least one running at all times;
  with one, a worker failure pauses imports and other background jobs until it
  is replaced.

A database failover is not seamless. Connections drop and requests in flight
fail until the standby takes over, typically within a minute or two.

| Path | App tier | Database failover |
| --- | --- | --- |
| Helm | `api.replicas` and `frontend.replicas` (both default to 2), `worker.replicas`, `titiler.replicas` (defaults to 1), plus a `topologySpreadConstraints` entry per component with `whenUnsatisfiable: DoNotSchedule`, so copies land on different nodes or zones | Your database. Use a managed service with failover and set `secrets.databaseUrlOverride` |
| AWS | `app_desired_count` in the recipe, or the ECS service's desired count | RDS Multi-AZ: `db_high_availability = true` in the recipe, or `--multi-az` when creating by hand |
| Azure | `app_replicas` in the recipe (needs `cache_enabled`), or the Container App's min and max replicas, with the worker pinned to at least 1 | Flexible Server zone-redundant high availability: `db_high_availability = true` in the recipe. It needs a General Purpose or Memory Optimized `db_sku_name`, not Burstable |
| Google Cloud | Cloud Run minimum and maximum instances | Cloud SQL high availability, `--availability-type=REGIONAL` |
| DigitalOcean | `instance_count` on the App Platform components | One or two standby nodes on a Standard Edition cluster, except on some 1 vCPU shared plans. New Standard Edition clusters can't add standby nodes from 15 October 2026 on an account that has never created a PostgreSQL or MySQL cluster, and from 30 November 2026 on every account; a cluster created before then keeps them. Advanced Edition has standby nodes but no PostGIS, so GeoLens can't run on it |

The Terraform recipes run no database standby unless you set
`db_high_availability = true`, which roughly doubles the database cost. Their
cache is one node without failover (`automatic_failover_enabled = false` on
AWS, `high_availability_enabled = false` on Azure), and each runs exactly one
worker task. Both default to one app replica, and the AWS production profile
requires exactly one app task.

### Before running more than one replica

Going from one replica to several turns on problems a single instance hides.
Beyond the shared storage and cache above:

- Add up the [database connections](#database-connections) and compare the
  total with the database's `max_connections`.
- Run migrations once, as a separate job, and set
  `GEOLENS_API_RUN_MIGRATIONS=false` on the api so replicas don't race to
  migrate at startup.
- Probe `/health/live` for liveness and `/health/ready` for readiness (images
  before GeoLens 1.21.0 have only `/health/live`, which the chart then uses for
  both), with a `failureThreshold` of 3 or more. Never probe `/health`: it also fails when the
  cache or object store is down, which would pull every replica out at once.
- Set `TRUSTED_PROXY_CIDRS` on the frontend to the load balancer's address
  range, or client IPs and rate limits all see the balancer.
- Give the platform a termination grace period longer than
  `UVICORN_TIMEOUT_GRACEFUL_SHUTDOWN` for the api and `WORKER_SHUTDOWN_TIMEOUT`
  for the worker (both default to 30 seconds), or in-flight requests and jobs
  are killed.
- Expect a setting changed in the admin UI to reach other replicas within
  about a minute, as their caches expire.

## Status

AWS and Azure have recipes applied against a real account, and their pages
carry what those runs found. The Google Cloud and DigitalOcean pages are written
from the application's configuration contract and each provider's own
documentation, not from a validated deployment. Corrections through issues and
pull requests are welcome.
