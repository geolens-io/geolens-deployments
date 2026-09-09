# DigitalOcean

Managed PostgreSQL, Spaces, and optionally Managed Valkey, with the containers
on App Platform or a Droplet running Compose.

There is no Terraform recipe yet;
[#43](https://github.com/geolens-io/geolens-deployments/issues/43) tracks one.
Nothing here has been applied against a real team, so treat it as a starting
point.

## Database: Managed PostgreSQL

```bash
doctl databases create geolens-db \
  --engine pg --version 15 --region nyc1 \
  --size db-s-1vcpu-1gb --num-nodes 1

doctl databases db create <db-id> geolens
doctl databases user create <db-id> geolens
```

A new cluster comes with a `doadmin` user and a `defaultdb` database and
nothing else, so the second and third commands are what make the `geolens`
database and login in the DSN below exist. `doctl databases user create` prints
the generated password once; take it from there rather than setting one.

The two logins do different jobs. Run the bootstrap as `doadmin`, because
creating extensions and the `geolens_reader` role needs privileges a login made
with `doctl databases user create` does not have. Then hand the database to the
runtime login, which is what Alembic connects as:

```sql
ALTER DATABASE geolens OWNER TO geolens;
ALTER SCHEMA catalog OWNER TO geolens;
ALTER SCHEMA data OWNER TO geolens;
```

Without that transfer the schemas stay owned by `doadmin` and the first
migration fails trying to create tables in them.

Two more things differ from the other clouds and both bite early.

**The cluster rejects every connection until you add a trusted source.** This
is not a network misconfiguration, it is the default. Add the Droplet, the App
Platform app, or your own address:

```bash
doctl databases firewalls append <db-id> --rule ip_addr:<your-app-ip>
```

**The port is 25060, not 5432,** and TLS is required. Take the connection
string from the console or `doctl databases connection <db-id> --format URI`
rather than assembling one by hand.

Confirm the engine version you picked carries pgvector 0.5 or newer before
committing to it; the HNSW index the application builds needs it. Then run the
bootstrap script from the
[cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/)
as `doadmin` against the `geolens` database, and apply the ownership transfer
above.

## Storage: Spaces

```bash
doctl spaces create geolens-uploads --region nyc3
```

Generate a key pair under API, Spaces Keys in the console. The Key becomes
`S3_ACCESS_KEY_ID` and the Secret becomes `S3_SECRET_ACCESS_KEY`. Spaces
speaks the S3 API, so this is an `STORAGE_PROVIDER=s3` deployment with
`S3_ENDPOINT=https://<region>.digitaloceanspaces.com`.

Browsers upload straight to the Space with presigned URLs, so it needs a CORS
policy. The console has a form for it, and the S3 API works too:

```bash
aws s3api put-bucket-cors \
  --endpoint-url https://nyc3.digitaloceanspaces.com \
  --bucket geolens-uploads \
  --cors-configuration '{
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

### TiTiler reads through GDAL

TiTiler runs no GeoLens code, so it never sees `S3_ENDPOINT` or the `S3_*`
credentials. It reads objects through GDAL's `/vsis3/` driver, which uses AWS's
own variable names. The bundled Compose entrypoint and the Helm chart translate
them for you. Assembling containers by hand means doing it yourself, on the
TiTiler container only:

```bash
AWS_S3_ENDPOINT=nyc3.digitaloceanspaces.com
AWS_ACCESS_KEY_ID=<spaces-key>
AWS_SECRET_ACCESS_KEY=<spaces-secret>
AWS_DEFAULT_REGION=nyc3
```

`AWS_S3_ENDPOINT` takes a host with no scheme, and GDAL assumes HTTPS unless
`AWS_HTTPS=NO` says otherwise. Without these, raster reads go to AWS while
uploads keep working, so the symptom looks unrelated to the endpoint.

## Cache

Managed Valkey where the region offers it, otherwise Valkey on a Droplet. The
application uses redis-py, which speaks to either. Skip it entirely for a
single instance, where the in-process cache is the right answer.

A managed cluster requires TLS and a password on port 25061, so its URL is
`rediss://default:<password>@<host>:25061/0`. Take it from the console rather
than assembling one. A plain `redis://` URL is for a cache you run yourself on
a Droplet's private network.

## Containers

App Platform has no sidecar concept, so the four containers become four
components: the frontend as the public service, the api and titiler as
internal services, and the worker as a worker component. That makes the
inter-component wiring mandatory. Point `API_UPSTREAM` on the frontend at the
api component and `TITILER_BASE_URL` on the api at the titiler component,
using App Platform's internal hostnames. The Compose defaults
(`http://api:8000` and `http://titiler:8000`) resolve to nothing between
components.

Because api and titiler land in separate components, titiler can keep port
8000. It only has to move when it shares a network namespace with the api,
which is the Droplet and Compose case.

Route the app's public domain to the frontend component. It is the application
edge, so serving the built bundle alone breaks `/api` proxying and raster
tiles.

On a Droplet, run the bundled Compose file with the managed-service
environment variables. The layout is the local one with the database, bucket
and cache pointed elsewhere.

## HTTPS

App Platform provisions and renews a Let's Encrypt certificate when you bind a
custom domain. On a Droplet, put Caddy or Traefik in front of the frontend
container on port 8080 and let it handle issuance. Afterwards, `PUBLIC_APP_URL` is the public hostname and
`PUBLIC_API_URL` is that hostname plus `/api`. Both feed OGC self-links, OAuth
redirects and generated distribution URLs, so dropping the suffix points
API links at the frontend root.

## Environment delta

Everything else stays as the
[cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/)
has it.

```bash
DATABASE_URL_OVERRIDE=postgresql://geolens:<password>@geolens-db-do-user-123456-0.db.ondigitalocean.com:25060/geolens
DATABASE_SSL_MODE=require

STORAGE_PROVIDER=s3
S3_ENDPOINT=https://nyc3.digitaloceanspaces.com
S3_BUCKET=geolens-uploads
S3_REGION=nyc3
S3_ACCESS_KEY_ID=<spaces-key>
S3_SECRET_ACCESS_KEY=<spaces-secret>

# Optional. Managed Valkey is TLS and password authenticated on 25061:
# REDIS_URL=rediss://default:<password>@geolens-cache-do-user-123456-0.db.ondigitalocean.com:25061/0
# A Valkey you run yourself on the private network is a plain redis:// URL.
```

An `sslmode` parameter in the connection string is harmless. The application
strips it and uses `DATABASE_SSL_MODE` instead.

## When it goes wrong

**The database connection times out or is refused.** No trusted source covers
the client. Add the App Platform app or the Droplet, not just your laptop.

**The connection is refused on port 5432.** Managed PostgreSQL listens on
25060.

**The login or the database does not exist.** Creating the cluster creates
`doadmin` and `defaultdb`. The `geolens` database and user are separate
commands.

**The bootstrap fails creating an extension or a role.** It is running as the
`geolens` login rather than `doadmin`.

**The first migration fails creating tables.** The schemas are still owned by
`doadmin`. Run the three `ALTER` statements above.

**Vector data works and raster tiles do not.** The titiler component is missing
its `AWS_*` variables, so GDAL is resolving against AWS.

**The baseline migration aborts on `vector`.** The cluster's engine version
does not offer pgvector. There is no parameter that adds it, so this is a
version choice, made before the cluster exists.
