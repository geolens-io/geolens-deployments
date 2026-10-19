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
- **A worker that can scale.** The worker can run more than one replica.
  Keep at least one running at all times.

A database failover is not seamless. Connections drop and requests in flight
fail until the standby takes over, typically within a minute or two.

| Path | App tier | Database failover |
| --- | --- | --- |
| Helm | `api.replicas` and `frontend.replicas` (both default to 2), `worker.replicas`, `titiler.replicas` (defaults to 1), plus a `topologySpreadConstraints` entry per component so copies land on different nodes or zones | Your database. Use a managed service with failover and set `secrets.databaseUrlOverride` |
| AWS | `app_desired_count` in the recipe, or the ECS service's desired count | RDS Multi-AZ (`--multi-az` when creating by hand) |
| Azure | `app_replicas` in the recipe (needs `cache_enabled`), or the Container App's min and max replicas, with the worker pinned to at least 1 | Flexible Server zone-redundant high availability. It needs a General Purpose or Memory Optimized SKU, not Burstable |
| Google Cloud | Cloud Run minimum and maximum instances | Cloud SQL high availability, `--availability-type=REGIONAL` |
| DigitalOcean | `instance_count` on the App Platform components | One or two standby nodes on the managed cluster, except on some 1 vCPU shared plans. New Standard Edition clusters can't add standby nodes for accounts created from 15 October 2026, or for any account from 30 November 2026; check the edition before you create the cluster |

The Terraform recipes run no database standby: the AWS recipe hardcodes
`multi_az = false` and the Azure recipe creates no `high_availability` block.
Their cache is one node without failover (`automatic_failover_enabled = false`
on AWS, `high_availability_enabled = false` on Azure). Both default to one app
replica, and the AWS production profile requires exactly one app task. A
standby roughly doubles the database cost.

## Status

AWS and Azure have recipes applied against a real account, and their pages
carry what those runs found. The Google Cloud and DigitalOcean pages are written
from the application's configuration contract and each provider's own
documentation, not from a validated deployment. Corrections through issues and
pull requests are welcome.
