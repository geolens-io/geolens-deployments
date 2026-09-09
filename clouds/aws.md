# AWS

RDS for PostgreSQL, S3, and optionally ElastiCache, with the containers on
ECS Fargate or on EC2 running Compose.

[`terraform/aws-ecs-fargate`](../terraform/aws-ecs-fargate/) provisions all of
this and was applied against a real account. Use it unless you need the
console path, and read this page for what it is doing.
[`examples/values-aws.yaml`](../examples/values-aws.yaml) is the EKS
equivalent for the Helm chart.

## Database: RDS for PostgreSQL

Create an instance on PostgreSQL 15 or newer. 13 is the application floor, but
pgvector arrives on RDS at 15.2 and 14.7, and semantic search needs pgvector
0.5+.

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

The application principal needs object read, write and delete on the bucket
plus `ListBucket`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::geolens-uploads",
        "arn:aws:s3:::geolens-uploads/*"
      ]
    }
  ]
}
```

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

TiTiler runs no GeoLens code, so it never sees the `S3_*` names. It reads
through GDAL's `/vsis3/` driver, which wants `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` and `AWS_DEFAULT_REGION`, or the task role. Native S3
needs no `AWS_S3_ENDPOINT`, which is the one thing that makes AWS simpler than
the S3-compatible stores. The bundled Compose entrypoint and the chart set
these for you; assembling containers by hand means setting them yourself.

Leave `S3_ENDPOINT` unset. The SDK picks the right regional endpoint on its
own, and setting it is how people accidentally pin the wrong region.

## Cache: ElastiCache

Optional, and only worth provisioning when more than one API instance runs.
A single-node `cache.t3.micro` Redis or Valkey cluster in the application's
VPC is enough. Open TCP 6379 from the application security group. With
`REDIS_URL` unset the application caches in process memory, which is correct
for a single instance and wrong for several.

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

Titiler defaults to port 8000, which the api already holds. The recipe moves
it to 8081 by overriding the container command; do the same wherever the two
share a network namespace.

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

**The migration aborts on a missing extension.** The bootstrap SQL did not
run, or it ran against a different database on the same instance. PostGIS
being present in the parameter group is not the same as the extension
existing in your database.

**pgvector is not available at all.** The engine version predates 15.2 or
14.7. Upgrade the instance; there is no parameter that adds it.

**Uploads fail with a missing `Access-Control-Allow-Origin` header.** The
bucket CORS policy does not list the origin the browser is on. It has to be
the public application origin, scheme included, not the bucket's own hostname.
