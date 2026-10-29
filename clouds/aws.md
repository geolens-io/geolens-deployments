# AWS

RDS for PostgreSQL, S3, and optionally ElastiCache, with the containers on
ECS Fargate or on EC2 running Compose.

[`terraform/aws-ecs-fargate`](../terraform/aws-ecs-fargate/) provisions all of
this and was applied against a real account. Use it unless you need the
console path, and read this page for what it is doing.
[`examples/values-aws.yaml`](../examples/values-aws.yaml) is the EKS
equivalent for the Helm chart.

The recipe's [Scaling section](../terraform/aws-ecs-fargate/README.md#scaling)
lists its knobs and the alarms worth setting. By hand, the equivalents are an
Application Auto Scaling target and target-tracking policy on the ECS service,
a worker service with its own desired count and a maximum storage threshold on
the instance. Every app task and worker task holds database connections, and a
rolling deploy runs old and new tasks together at the default 200% maximum, so
read the [connection budget](README.md#database-connections) before raising
either count.

For a production deployment, use the recipe's
[single-organization production profile](../terraform/aws-ecs-fargate/README.md#production-profile).
Each organization gets a separate stack and RDS instance. Shared RDS is not a
supported configuration for this recipe.

## Database: RDS for PostgreSQL

Create an instance on PostgreSQL 15 or newer. 15 is the application floor: the
baseline migration aborts below it with `GeoLens requires PostgreSQL 15+ (NULLS
NOT DISTINCT unique indexes)`. Semantic search also needs pgvector 0.5+, which
RDS ships from 15.4-R2, so upgrade an older 15 minor before installing.

Set the initial database name and the master username when you create the
instance, because RDS creates no database at all unless you ask for one and the
master username defaults to `postgres`. The recipe uses `geolens` for both, and
so does every DSN on this page.

```bash
aws rds create-db-instance \
  --db-instance-identifier geolens-db \
  --engine postgres --engine-version 15 \
  --db-instance-class db.t4g.medium --allocated-storage 20 \
  --storage-type gp3 --storage-encrypted \
  --db-name geolens --master-username geolens \
  --master-user-password "$DB_PASSWORD"
```

Keep `--storage-encrypted`. Encryption cannot be turned on in place afterwards;
undoing the omission means a snapshot copy and a restore.

For a standby, add `--multi-az`: RDS keeps a synchronous copy in a second zone
and fails over to it automatically, for about twice the instance cost.
Connections drop during a failover, so requests in flight fail. The recipe sets
it with `db_high_availability = true`.

PostGIS is in the default RDS parameter group, and `pg_trgm`, `unaccent` and
`vector` are available on those engine versions. None of them are created for
you. Connect with `psql` as the master user and run the bootstrap SQL from the
[cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/):
it creates the four extensions, the `catalog` and `data` schemas, and the
`geolens_reader` role. The console cannot create the role, so `psql` is the
only path.

```bash
psql -h geolens-db.abc123.us-east-1.rds.amazonaws.com -U geolens -d geolens
```

Confirm afterwards:

```sql
SELECT extname, extversion FROM pg_extension
 WHERE extname IN ('postgis', 'pg_trgm', 'vector', 'unaccent');
```

RDS requires TLS, so set `DATABASE_SSL_MODE=require`.

### ECS database boundary

The ECS recipe currently gives the RDS master login to the API, worker and
migration task. GeoLens 1.27.1 supports canonical runtime-role settings, but
the published API image does not include the repository-level managed-database
bootstrap/reconciliation helper that the recipe would need to create and verify
that role. Keep organizations on separate RDS instances and keep the
master credential inside that stack's Secrets Manager secret. Do not reuse one
RDS cluster or hand end users the master credential, Terraform state or AWS
account credentials. The recipe's README records the follow-up needed before
runtime-role or shared-RDS support can be claimed.

## Storage: S3

```bash
aws s3 mb s3://geolens-uploads --region us-east-1
```

Browsers upload straight to the bucket with presigned URLs, so the bucket
needs a CORS policy naming your application origin:

```bash
aws s3api put-bucket-cors --bucket geolens-uploads --cors-configuration '{
  "CORSRules": [
    {
      "AllowedOrigins": ["https://geolens.example.com"],
      "AllowedMethods": ["GET", "PUT", "POST", "DELETE"],
      "AllowedHeaders": ["*"],
      "ExposeHeaders": ["ETag"],
      "MaxAgeSeconds": 3600
    }
  ]
}'
```

The application principal needs object read, write and delete, plus the
multipart actions. Uploads above `PRESIGNED_MULTIPART_THRESHOLD_MB`, which
defaults to 100 MB, are multipart, and without `AbortMultipartUpload` a
cancelled upload leaves parts in the bucket that nothing can clean up. This is
the same split the Terraform recipe applies:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": ["arn:aws:s3:::geolens-uploads"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::geolens-uploads/*"]
    }
  ]
}
```

Add a lifecycle rule with `AbortIncompleteMultipartUpload` as a backstop, since
an upload that is neither completed nor aborted leaves parts no application
sweep can see. Add a bucket policy that denies any request where
`aws:SecureTransport` is false, as the recipe does; the application, Titiler
and the presigned URLs all use HTTPS already.

The recipe aborts incomplete multipart uploads after seven days on every
bucket. The production profile also enables bucket versioning and expires
noncurrent versions after 30 days by default. In a versioned bucket, an
application delete hides an object by adding a delete marker; prior versions
remain until lifecycle removes them. Current objects do not expire
automatically, and lifecycle expiration is asynchronous.

Give Titiler a second, read-only principal scoped to `rasters/*` and
`tenants/*/rasters/*`, and set `TITILER_S3_ACCESS_KEY_ID` and
`TITILER_S3_SECRET_ACCESS_KEY` to it. Left unset, Titiler falls back to the
application's read-write credential. The
[chart README](../helm/geolens/README.md#titiler-read-only-s3-credentials)
has the prefixes and an example policy.

On ECS and EKS you can skip static keys entirely: attach the task role or the
IRSA-annotated ServiceAccount and leave `S3_ACCESS_KEY_ID` and
`S3_SECRET_ACCESS_KEY` unset. The backend detects the ambient credential and
lets boot proceed.

The ECS production profile creates a different bucket and task policy per
organization. Its `Deployment` tag supports per-stack cost reporting after
the tag is activated in AWS Billing. S3 has no hard bucket-size quota in this
recipe; agree a storage limit and configure a cost alert for each organization.

TiTiler runs no GeoLens code, so it never sees the `S3_*` names. It reads
through GDAL's `/vsis3/` driver, which wants `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` and `AWS_DEFAULT_REGION`, or the task role. Native S3
needs no `AWS_S3_ENDPOINT`, which is the one thing that makes AWS simpler than
the S3-compatible stores. The bundled Compose entrypoint and the chart set
these for you; assembling containers by hand means setting them yourself.

Leave `S3_ENDPOINT` unset. The SDK picks the right regional endpoint on its
own, and setting it is how people accidentally pin the wrong region.

## Cache: ElastiCache

Provision one unless no service you import needs a token. From 1.23.0 the api
hands a service token to the worker through the cache, so importing,
re-uploading or refreshing such a service answers 503 without `REDIS_URL`,
even on a single instance. A single-node `cache.t4g.micro` Redis or Valkey
cluster in the application's VPC is enough. Open TCP 6379 from the application
security group. Everything else works with `REDIS_URL` unset: the application
then caches in process memory, which is correct for a single instance and
wrong for several.

## Containers

The four containers are the frontend edge, the api, the worker and titiler.
Only the frontend takes public traffic.

Both inter-container hops default to Compose service names that do not resolve
on ECS. Set `API_UPSTREAM` on the frontend and `TITILER_BASE_URL` on the api
to whatever your topology makes reachable: `http://127.0.0.1:8000` and
`http://127.0.0.1:8081` when the containers share one `awsvpc` task, or the
Service Connect or Cloud Map names when they are separate services. Left at
their defaults, `/api` returns an nginx upstream error and raster tiles never
render.

Titiler reads remote (STAC) rasters through an internal route on the api, so
set `REMOTE_RASTER_RELAY_BASE_URL` on the api and worker to an origin titiler
can reach: `http://127.0.0.1:8000` in a shared task. Route `/api` to the
frontend edge, which refuses `/api/internal/`, never straight to the api.

Titiler defaults to port 8000, which the api already holds. The recipe moves
it to 8081 by overriding the container command; do the same wherever the two
share a network namespace.

Run every container with `readonlyRootFilesystem` and
`linuxParameters.capabilities.drop = ["ALL"]`, and titiler as `1001:1001`,
since its image declares no user. Each then needs task volumes at the paths it
writes: `/tmp` and `/var/cache/nginx` on the frontend, `/tmp` on titiler, and
`/tmp`, `/home/appuser` and `/app/staging` on the api, the worker and the
migrate task, whose entrypoint refuses to start without a writable staging
directory. Fargate creates task volumes owned by root with mode 0755, so a
non-root container cannot write them; the recipe runs a non-essential root
container that `chmod 1777`s them first, and the others depend on its
success.

For one-off commands such as `scripts.trust_login_device`, run the migrate
task definition with `aws ecs run-task --overrides` and a replaced command, as
the recipe README shows, or turn on ECS Exec.

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
migration time, and leave the services on the previous release until it
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
it doesn't know; `scripts.trust_login_device <username>`, run as
above, prints a link that lets an admin back in once, within 10 minutes.

Upgrading to 1.26.0: migrations 0084 to 0086 are additive. 0085 waits at most
5 seconds for its lock on `catalog.datasets` instead of queueing behind other
writes, so on a busy catalog the migration can fail with a lock timeout.
Leave the services on the previous release and run the migrate task again
before rolling them onto 1.26.0.

Upgrading to 1.27.1: from 1.26, upgrade straight to 1.27.1 rather than 1.27.0.
1.27.0's migration 0088 drops columns that 1.26 reads, so 1.26 tasks still
serving during the rollout fail dataset requests and jobs until they are
replaced; 1.27.1 keeps those columns. Migrations 0087 to 0094 run. 0088 and
0091 to 0094 wait at most 5 seconds for their locks instead of queueing behind
other writes, so on a busy catalog the migration can fail with a lock timeout.
Leave the services on the previous release and run the migrate task again
before rolling them onto 1.27.1. 0088 moves each dataset's kept previous
version onto its version row, so rolling back below 1.27 refuses while any
dataset keeps more than one previous version. From 1.27.0, no migration runs.

Upgrading to 1.28.0: migrations 0095 and 0096 only add tables and a nullable
column, so 1.27 tasks keep serving during the rollout. Both wait at most 5
seconds for their locks on the users and maps tables instead of queueing
behind other writes, so on a busy catalog the migration can fail with a lock
timeout. Leave the services on the previous release and run the migrate task
again before rolling them onto 1.28.0.

## HTTPS

Issue an ACM certificate, put an ALB in front with an HTTPS listener, and
target the frontend container on port 8080. The frontend proxies `/api` and
`/raster-tiles` itself, so it is the only target the ALB needs. Restrict the
task security group to accept 8080 from the ALB security group alone.

Serving the built bundle from S3 and CloudFront instead skips the frontend
edge, which is what blocks unauthenticated `/api/metrics` and rate-limits
anonymous raster traffic. Do not do it.

## Environment delta

Everything else stays as the
[cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/)
has it.

```bash
DATABASE_URL_OVERRIDE=postgresql://geolens:<password>@geolens-db.abc123.us-east-1.rds.amazonaws.com:5432/geolens
DATABASE_SSL_MODE=require

STORAGE_PROVIDER=s3
S3_BUCKET=geolens-uploads
S3_REGION=us-east-1
# Omit both keys when the task role or IRSA supplies credentials.
S3_ACCESS_KEY_ID=<access-key-id>
S3_SECRET_ACCESS_KEY=<secret-access-key>
TITILER_S3_ACCESS_KEY_ID=<read-only-key-id>
TITILER_S3_SECRET_ACCESS_KEY=<read-only-secret>
# S3_ENDPOINT stays unset on native S3.

REDIS_URL=redis://geolens-cache.abc123.0001.use1.cache.amazonaws.com:6379/0
```

## When it goes wrong

**`psql` reports that the database does not exist.** The instance was created
without `--db-name`, so RDS made none. Create one with `CREATE DATABASE geolens`
as the master user before running the bootstrap.

**The migration aborts on a missing extension.** The bootstrap SQL did not
run, or it ran against a different database on the same instance. PostGIS
being present in the parameter group is not the same as the extension
existing in your database.

**The migration fails with `access method "hnsw" does not exist`.** pgvector
is missing or older than 0.5. Check with `SELECT extversion FROM pg_extension
WHERE extname = 'vector'`. No row means the bootstrap SQL didn't run. An older
version needs `ALTER EXTENSION vector UPDATE`, and if it stays below 0.5 the
engine predates 15.4-R2: upgrade the instance's minor version first, since no
parameter adds a newer pgvector.

**Uploads fail with a missing `Access-Control-Allow-Origin` header.** The
bucket CORS policy does not list the origin the browser is on. It has to be
the public application origin, scheme included, not the bucket's own hostname.
