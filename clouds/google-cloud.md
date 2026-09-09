# Google Cloud

Cloud SQL for PostgreSQL, a Cloud Storage bucket reached through its
S3-compatible API, and optionally Memorystore, with the containers on
Cloud Run.

There is no Terraform recipe yet;
[#42](https://github.com/geolens-io/geolens-deployments/issues/42) tracks one.
Nothing here has been applied against a real project, so treat it as a
starting point.

## Database: Cloud SQL for PostgreSQL

Create an instance on PostgreSQL 15 or newer. PostGIS, `pg_trgm` and
`unaccent` can be created directly once the instance exists. pgvector is the
one to check: confirm it is offered for the engine version and region you are
about to pick, because the baseline migration aborts without it and no
parameter adds it later.

```bash
gcloud sql instances create geolens-db \
  --database-version=POSTGRES_15 \
  --tier=db-custom-2-4096 \
  --region=us-central1

gcloud sql databases create geolens --instance=geolens-db
gcloud sql users create geolens --instance=geolens-db --password=<password>
```

Connect through the Cloud SQL Auth Proxy, then run the bootstrap SQL from the
[cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/).

```bash
cloud-sql-proxy geolens-project:us-central1:geolens-db &
psql -h 127.0.0.1 -U geolens -d geolens
```

### Reaching the instance from Cloud Run

A Cloud SQL instance is not reachable from Cloud Run by default, and this is
the step that gets skipped. Pick one of two shapes.

Run the Auth Proxy as a sidecar in the same multi-container service. It listens
on loopback, holds the encrypted connection to Cloud SQL itself, and the
application dials `127.0.0.1:5432` with `DATABASE_SSL_MODE=disable`, because
the hop it is disabling is the one inside the container. Grant the service
account `roles/cloudsql.client`. The worker needs its own copy of the sidecar,
since it is a separate service.

Or give the instance a private IP and reach it over the VPC. That needs private
services access configured on the network, the instance attached to it, and
Direct VPC egress or a Serverless VPC Access connector on every Cloud Run
service that talks to the database. The same connector then serves Memorystore.
Neither the instance-creation commands above nor `REDIS_URL` set any of that up
for you.

Use `DATABASE_SSL_MODE=require`. The server CA is downloadable, but the
instance certificate identifies the instance connection name rather than the
IP address you connect to, so `verify-full` fails hostname verification against
a bare Cloud SQL IP no matter which CA is mounted. Reach for `verify-full` only
if you front the instance with a name the certificate carries.

```bash
gcloud sql ssl server-ca-certs list --instance=geolens-db --format="value(cert)" > server-ca.pem
```

That certificate is still worth having for pinning the CA in tools that check
it independently.

## Storage: Cloud Storage

GeoLens reaches Cloud Storage through its S3-compatible XML API, so this is an
`STORAGE_PROVIDER=s3` deployment with an endpoint override, not a separate
provider.

```bash
gcloud storage buckets create gs://geolens-uploads --location=us-central1

gcloud storage buckets add-iam-policy-binding gs://geolens-uploads \
  --member=serviceAccount:<service-account>@<project>.iam.gserviceaccount.com \
  --role=roles/storage.objectAdmin

gcloud storage buckets add-iam-policy-binding gs://geolens-uploads \
  --member=serviceAccount:<service-account>@<project>.iam.gserviceaccount.com \
  --role=roles/storage.legacyBucketReader

gcloud storage hmac create <service-account>@<project>.iam.gserviceaccount.com
```

The IAM binding is the step that is easy to miss. An HMAC key carries the
permissions of the service account it belongs to and grants nothing by itself,
so a key created against an account with no binding on the bucket returns 403
on every upload and every tile read while looking perfectly well formed.
`roles/storage.objectAdmin` covers the object reads, writes, deletes and
multipart operations the application performs. It does not carry
`storage.buckets.get`, which the XML API needs for the bucket metadata call
behind `s3:GetBucketLocation`, so `roles/storage.legacyBucketReader` goes
alongside it. Scope both to the bucket rather than the project.

The HMAC key's `accessId` and `secret` become `S3_ACCESS_KEY_ID` and
`S3_SECRET_ACCESS_KEY`. A service account key in JSON form is not a
substitute; the S3 API only accepts HMAC.

Browsers upload straight to the bucket with presigned URLs, so the bucket
needs CORS. Save this as `cors.json` and apply it:

```json
[
  {
    "origin": ["https://geolens.example.com"],
    "method": ["GET", "PUT", "POST", "DELETE"],
    "responseHeader": ["ETag"],
    "maxAgeSeconds": 3600
  }
]
```

```bash
gcloud storage buckets update gs://geolens-uploads --cors-file=cors.json
```

Set `S3_ENDPOINT=https://storage.googleapis.com` and `S3_REGION=auto`.
Multipart uploads through the XML API are the part worth exercising before you
commit: test an upload above `PRESIGNED_MULTIPART_THRESHOLD_MB`, which
defaults to 100 MB, rather than assuming it behaves like S3.

### TiTiler reads through GDAL

TiTiler runs no GeoLens code, so it never sees `S3_ENDPOINT` or the `S3_*`
credentials. It reads objects through GDAL's `/vsis3/` driver, which uses AWS's
own variable names. The bundled Compose entrypoint and the Helm chart translate
them for you. Assembling containers by hand means doing it yourself, on the
TiTiler container only:

```bash
AWS_S3_ENDPOINT=storage.googleapis.com
AWS_ACCESS_KEY_ID=<hmac-access-id>
AWS_SECRET_ACCESS_KEY=<hmac-secret>
AWS_DEFAULT_REGION=auto
```

`AWS_S3_ENDPOINT` takes a host with no scheme. GDAL assumes HTTPS unless
`AWS_HTTPS=NO` says otherwise, which is right here. Add
`AWS_VIRTUAL_HOSTING=FALSE` only if you set `S3_ADDRESSING_STYLE=path` on the
api. Skip this and raster tiles are read from AWS instead of Cloud Storage,
while uploads keep working, so the symptom looks unrelated to the endpoint.

## Cache: Memorystore

Optional, and only worth provisioning for more than one API instance.

```bash
gcloud redis instances create geolens-cache --size=1 --region=us-central1
gcloud redis instances describe geolens-cache --region=us-central1 --format="value(host)"
```

Memorystore is reachable only from inside its VPC, which for Cloud Run means
Serverless VPC Access or Direct VPC egress. Without one of those, `REDIS_URL`
points at an address the service cannot open.

## Containers

Cloud Run multi-container services cover the frontend, api and titiler in one
service sharing a network namespace. The worker is a long-running process, so
it needs its own service with CPU always allocated and minimum instances 1, or
a small Compute Engine VM.

A Cloud Run service has to listen on the port it is configured with, which
defaults to 8080. The worker image serves its health and metrics endpoints on
8001 and nothing on 8080, so deploy it with `--port 8001` or Cloud Run fails
the container's startup probe and never runs a job. That probe only answers
after schema sync and storage bootstrap, so allow a startup period of a couple
of minutes.

Set `API_UPSTREAM` on the frontend and `TITILER_BASE_URL` on the api. Within
one multi-container service both are loopback addresses, and titiler has to
move off port 8000 because the api holds it. Across separate services they are
the other service's URL, and that is where Cloud Run gets interesting: a
private service expects a Google-signed ID token on every request, and neither
hop mints one. The frontend proxies with plain nginx whose `Authorization`
header already carries the user's GeoLens JWT, and the api's titiler client is
an ordinary HTTP client. Either run the api and titiler with ingress-restricted
unauthenticated invocation, or put something in front that attaches the token
out of band, for which `X-Serverless-Authorization` exists. Granting the
invoker role by itself does not make either call work.

Route the public domain to the frontend. It is the application edge, so
serving the built bundle from a bucket instead breaks `/api` proxying and
raster tiles.

## HTTPS

Cloud Run terminates TLS on its own `*.run.app` hostnames. For a custom
domain, use a Cloud Run domain mapping or an HTTPS load balancer with a
Google-managed certificate. Afterwards, `PUBLIC_APP_URL` is the public hostname and
`PUBLIC_API_URL` is that hostname plus `/api`. Both feed OGC self-links, OAuth
redirects and generated distribution URLs, so dropping the suffix points
API links at the frontend root.

## Environment delta

Everything else stays as the
[cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/)
has it.

```bash
DATABASE_URL_OVERRIDE=postgresql://geolens:<password>@10.20.30.40:5432/geolens
DATABASE_SSL_MODE=require

STORAGE_PROVIDER=s3
S3_ENDPOINT=https://storage.googleapis.com
S3_BUCKET=geolens-uploads
S3_REGION=auto
S3_ACCESS_KEY_ID=<hmac-access-id>
S3_SECRET_ACCESS_KEY=<hmac-secret>

REDIS_URL=redis://10.0.0.5:6379/0
```

## When it goes wrong

**Storage returns 403 or an invalid-signature error.** Either `S3_ENDPOINT` is
unset, so the SDK is talking to AWS, or the credentials are a service account
key rather than an HMAC pair.

**Vector data works and raster tiles do not.** The TiTiler container is missing
its `AWS_*` variables, so GDAL is resolving against AWS.

**`/api` returns an nginx upstream error on Cloud Run.** `API_UPSTREAM` still
points at `http://api:8000`, or the api service is private and the frontend's
proxied request carries no ID token.

**The worker never starts on Cloud Run.** The service is on the default port
8080 and the worker only listens on 8001.

**The cache connection times out.** The Cloud Run service has no VPC connector
or Direct VPC egress, so it cannot reach Memorystore's private address. A
private-IP Cloud SQL connection fails the same way for the same reason.

**Storage returns 403 with a well-formed HMAC key.** The key's service account
has no IAM binding on the bucket. A 403 during storage bootstrap while object
reads work is the bucket metadata call, which needs
`roles/storage.legacyBucketReader` on top of `objectAdmin`.
