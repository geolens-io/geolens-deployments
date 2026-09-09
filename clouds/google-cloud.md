# Google Cloud

Cloud SQL for PostgreSQL, a Cloud Storage bucket reached through its
S3-compatible API, and optionally Memorystore, with the containers on
Cloud Run.

There is no Terraform recipe yet;
[#42](https://github.com/geolens-io/geolens-deployments/issues/42) tracks one.
Nothing here has been applied against a real project, so treat it as a
starting point.

## Database: Cloud SQL for PostgreSQL

Create an instance on PostgreSQL 15 or newer with the `postgis` database flag
enabled. pgvector is offered on 15 and later; confirm it in your region before
committing to an instance, because the baseline migration aborts without it.

```bash
gcloud sql instances create geolens-db \
  --database-version=POSTGRES_15 \
  --tier=db-custom-2-4096 \
  --region=us-central1

gcloud sql databases create geolens --instance=geolens-db
gcloud sql users create geolens --instance=geolens-db --password=<password>
```

Connect through the Cloud SQL Auth Proxy or a direct IP, then run the
bootstrap SQL from the
[cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/).

```bash
cloud-sql-proxy geolens-project:us-central1:geolens-db &
psql -h 127.0.0.1 -U geolens -d geolens
```

Cloud SQL is the one cloud here where `verify-full` is straightforward, since
the server CA is downloadable. Fetch it, mount it into the containers, and set
`DATABASE_SSL_CA_CERT` alongside `DATABASE_SSL_MODE=verify-full`.

```bash
gcloud sql ssl server-ca-certs list --instance=geolens-db --format="value(cert)" > server-ca.pem
```

## Storage: Cloud Storage

GeoLens reaches Cloud Storage through its S3-compatible XML API, so this is an
`STORAGE_PROVIDER=s3` deployment with an endpoint override, not a separate
provider.

```bash
gcloud storage buckets create gs://geolens-uploads --location=us-central1
gcloud storage hmac create <service-account>@<project>.iam.gserviceaccount.com
```

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
Google-managed certificate. Set `PUBLIC_APP_URL` and `PUBLIC_API_URL` to the
public hostname afterwards.

## Environment delta

Everything else stays as the
[cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/)
has it.

```bash
DATABASE_URL_OVERRIDE=postgresql://geolens:<password>@10.20.30.40:5432/geolens
DATABASE_SSL_MODE=verify-full
DATABASE_SSL_CA_CERT=/certs/server-ca.pem

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

**`/api` returns an nginx upstream error on Cloud Run.** `API_UPSTREAM` still
points at `http://api:8000`, or the api service is private and the frontend's
proxied request carries no ID token.

**The cache connection times out.** The Cloud Run service has no VPC connector
or Direct VPC egress, so it cannot reach Memorystore's private address.
