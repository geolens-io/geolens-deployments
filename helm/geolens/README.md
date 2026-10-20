# GeoLens Helm chart

Kubernetes packaging for [GeoLens](https://github.com/geolens-io/geolens). See
the [repository README](../../README.md) for how this chart is published,
versioned, and supported.

The chart deploys the API, worker, frontend (the app's edge nginx), Titiler
(raster tiles), and an Alembic migration hook Job against an externally managed
PostgreSQL and an optional Redis-compatible cache (the compose stack ships
Valkey). It does **not** install PostgreSQL, object storage, or the cache —
those remain operator-owned services.

Every value is documented inline in [`values.yaml`](values.yaml), usually with
the reasoning behind its default. This file covers the parts that need more than
a comment.

The commands below install from a checkout, so they name the chart by its path,
`helm/geolens`, and assume you are at the repository root. To install from the
hosted repository instead, substitute `geolens/geolens`, or the OCI reference
`oci://ghcr.io/geolens-io/charts/geolens`.

## Traffic topology

The ingress (or your own edge) sends **all** traffic to the frontend Service.
The frontend image's nginx proxies `/api` and raster-tile paths to the API
Service — stripping the `/api` prefix the backend does not serve — while
blocking the unauthenticated `/api/metrics` endpoint, rate-limiting anonymous
raster traffic, and redacting credentialed paths from its access log. Don't
route around it.

Probes: the api's startup and liveness probes use the process-only
`/health/live` (app images 1.18.0 and later). Readiness uses `/health/ready`
when `api.image.tag` is a release tag of 1.21.0 or later, so a pod that cannot
reach the database stays out of the Service and a rollout with a bad DSN or a
blocking NetworkPolicy stalls while the old pods keep serving. Older and
non-release tags keep `/health/live`, which older images still answer.
`/health/ready` leaves out the cache and the object store on purpose. The deep
`/health` check fails whenever the optional cache is unreachable, even though
the api keeps serving from its in-memory fallback, so as a readiness probe it
would pull every api pod out of the Service during a Valkey outage and every
`/api` request would return 502. Liveness stays process-only because restarting
pods during a database outage only churns them. Point monitoring at
`/api/health` for dependency status.

Client addresses: the chart sets `FORWARDED_ALLOW_IPS="*"` on the api, so
uvicorn takes the client address from the `X-Forwarded-For` header the frontend
edge overwrites. Without it, every request looks like it comes from the
frontend pod, all users share one set of rate-limit buckets, and five failed
logins from anyone lock everyone out for a minute. Any pod that can reach the
api Service directly can set that header too. If untrusted workloads share the
cluster, narrow the value to your pod CIDR through `api.extraEnv`.

Known limitation behind an ingress controller: the frontend nginx overwrites
forwarded headers (deliberate anti-spoofing when it is the true edge), so the
controller's IP becomes "the client" — the anonymous raster rate limit shares
one bucket across all users and backend logs/rate limits lose the real client
IP. Set `frontend.trustedProxyCidrs` to the CIDRs of every proxy in front of the
chart (frontend images >= 1.4.10); nginx walks `X-Forwarded-For` right to left
skipping trusted entries, so a missing hop stops resolution early. Older
frontend images have no trusted-proxy support at all; the change landed as
[geolens#581](https://github.com/geolens-io/geolens/issues/581).

> [!NOTE]
> Proxying through the frontend requires frontend image **1.4.9 or newer** —
> older images hardwire a Docker-compose-only upstream and ignore the chart's
> `API_UPSTREAM` env, and no alternative topology works with them. The
> chart's default tags satisfy this; if you pin an older tag, `helm install`
> prints a warning and API traffic will not work.

Ingress body size and timeouts: uploads go through the ingress, and controller
defaults are small. ingress-nginx caps the body at 1m and times out at 60s, so
set `nginx.ingress.kubernetes.io/proxy-body-size` to at least
`api.uploadMaxSizeMb`, raise `proxy-read-timeout` and `proxy-send-timeout`, and
set `proxy-request-buffering: "off"` so a large upload streams through.
[`examples/values-aws.yaml`](../../examples/values-aws.yaml) shows the set. The
AWS Load Balancer Controller takes the idle timeout from
`alb.ingress.kubernetes.io/load-balancer-attributes:
idle_timeout.timeout_seconds=600`, and GKE reads `timeoutSec` from a
BackendConfig attached to the frontend Service.

## Required values

The backend refuses to boot without admin credentials, a JWT secret, and a
database URL. Keep them off the Helm command line: arguments show up in shell
history, process listings and CI logs. Write them to a file only you can read,
create a Secret from it, and point the chart at that Secret:

```bash
cat > /secure/path/geolens.env <<EOF
DATABASE_URL_OVERRIDE=postgresql+asyncpg://geolens:change-me@postgres.internal:5432/geolens
JWT_SECRET_KEY=$(openssl rand -hex 32)
GEOLENS_ADMIN_USERNAME=admin
GEOLENS_ADMIN_PASSWORD=a-strong-unique-password
POSTGRES_PASSWORD=unused
EOF
kubectl create secret generic geolens-secrets --from-env-file=/secure/path/geolens.env

helm upgrade --install geolens helm/geolens \
  --set secrets.existingSecret=geolens-secrets \
  --set api.publicAppUrl=https://maps.example.com \
  --set api.publicApiUrl=https://maps.example.com/api \
  --set ingress.enabled=true --set ingress.host=maps.example.com
```

An External Secrets, SOPS or sealed-secrets controller that produces the same
Secret works the same way. The chart also accepts the credentials directly as
`secrets.databaseUrlOverride`, `secrets.jwtSecretKey`, `secrets.adminUsername`
and `secrets.adminPassword`, which it writes into a chart-managed Secret. That
is for a values file you never commit, or a throwaway cluster; do not pass
them as `--set` arguments.

Keys the chart reads from an `existingSecret`:

| Key | Required | Purpose |
| --- | --- | --- |
| `DATABASE_URL_OVERRIDE` | yes | async SQLAlchemy DSN of your PostgreSQL |
| `JWT_SECRET_KEY` | yes | JWT signing secret, ≥ 32 chars |
| `GEOLENS_ADMIN_USERNAME` | yes | initial admin login |
| `GEOLENS_ADMIN_PASSWORD` | yes | initial admin password (known-public example values are rejected at boot) |
| `POSTGRES_PASSWORD` | yes | required by backend settings even when `DATABASE_URL_OVERRIDE` carries the real credentials — any placeholder (e.g. `unused`) satisfies it; the chart-managed Secret sets one automatically |
| `TILE_SIGNING_SECRET` | no | signed tile URLs |
| `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` | no | AI features |
| `REDIS_URL` | no | the cache the api and worker share, which token-protected service imports need since 1.23.0. A URL with a password belongs here: with an `existingSecret`, `redis.url` renders into the ConfigMap, and this key wins over it |
| `SECRET_ENCRYPTION_KEY` | no | dedicated key for the secrets GeoLens stores; empty derives it from `JWT_SECRET_KEY` (app images ≥ 1.18.2) |
| `SECRET_ENCRYPTION_KEY_PREVIOUS` | no | the previous key during a rotation; never set it without `SECRET_ENCRYPTION_KEY`, the backend refuses to boot |
| `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | when `storage.backend=s3` and `storage.s3AmbientCredentials` is false | shared object-storage credentials; Titiler uses these only as the compatibility fallback described below. With `storage.s3AmbientCredentials=true` (app images ≥ 1.14.2) both are omitted and the SDKs resolve a role instead — see [Keyless object storage](#keyless-object-storage-irsa--pod-identity) |

The chart sets `ENVIRONMENT=production` by default (API docs hidden, Secure
session cookie). Override with `--set environment=development` only on
throwaway clusters.

Serve the ingress over HTTPS. Browsers drop the Secure session cookies on a
plain-HTTP origin, so a sign-in lasts only until the access token expires, and
the import form needs a secure context (it calls `crypto.randomUUID`, which
browsers withhold from plain HTTP). The `kubectl port-forward` in the install
notes is fine, because browsers treat `localhost` as secure.

Upload sizes: `api.uploadMaxSizeMb` is rendered onto the frontend edge as
`CLIENT_MAX_BODY_SIZE` too, so raising it no longer needs a second change
([geolens#580](https://github.com/geolens-io/geolens/issues/580), shipped in
frontend 1.4.10). Frontend images older than 1.4.10 ignore that variable and
stay at the baked 500m, rejecting larger uploads at the edge with 413.

### Rotating the stored-secret encryption key

Both backend images must be 1.18.2 or newer before you start. The chart
checks that only for the `secrets.*` values; a key placed in your own Secret
is invisible to it, and an older image ignores the key silently, so the
rotation below would not happen. Pods also read the Secret only when they
start, and with `secrets.existingSecret` nothing restarts them for you: the
`checksum/secret` annotation that rolls the api and worker exists only for
the chart-managed Secret. So each step below ends with a restart.

1. Add the new key as `SECRET_ENCRYPTION_KEY` and move the old one to
   `SECRET_ENCRYPTION_KEY_PREVIOUS` in your Secret (or set the matching
   `secrets.*` values and `helm upgrade`).
2. Restart both consumers so every pod holds both keys:
   `kubectl rollout restart deploy/<release>-api deploy/<release>-worker`,
   and wait for the rollout to finish.
3. Run `backend/scripts/rotate_secrets.py` inside one api pod with
   `kubectl exec`.
4. Remove `SECRET_ENCRYPTION_KEY_PREVIOUS` and restart both again. A pod that
   starts after this step with the old configuration cannot decrypt anything
   the script re-encrypted, which is why step 2 must have completed first.

The full procedure is section 11 of the GeoLens
[RUNBOOK](https://github.com/geolens-io/geolens/blob/main/RUNBOOK.md).

## Storage and the shared staging volume

`/app/staging` is scratch space: the api writes uploads there, the worker
reads them to ingest, and Titiler reads rasters under it. By default each pod
gets its own `emptyDir`. Whether that matters depends entirely on the storage
backend:

- **Use `storage.backend=s3`.** This is the one that matters.
  `storage.backend=local` keeps stored rasters and exports inside the staging
  volume, so without persistence they are lost on every pod restart.
- **`staging.persistence` is then optional.** With s3, an upload is written to
  the bucket under a relative key and the worker fetches it from there, so the
  api/worker handoff never crosses a filesystem — measured by ingesting vector
  and raster data across pods with no shared volume at all. Enable it (a
  `ReadWriteMany` PVC, or `staging.persistence.existingClaim`) only if you want
  a shared scratch filesystem for its own sake.
- **With `storage.backend=azure`, enable it.** Only s3 hands an upload to
  the worker through the bucket. With azure the api stages the upload at
  `/app/staging` and the worker reads that path, so without a shared claim
  every import fails at "validating" with `BlobNotFound`. On AKS, RWX means
  Azure Files. Its SMB mounts present every file as owned by the mount, so
  give the StorageClass the `uid=1001` and `gid=1001` mount options (the
  backend images' user), or raster conversion fails with
  `Operation not permitted`.
- **On EKS, do not enable it with the defaults.** `ReadWriteMany` is rejected
  outright by the EBS CSI driver (`Volume capabilities not supported`), and an
  empty `staging.persistence.storageClass` renders no `storageClassName`, which
  needs a cluster *default* StorageClass that an eksctl-built cluster does not
  mark — the claim then sits `Pending` forever. RWX on AWS means EFS.

ReadWriteMany by cloud, for the cases above that need a shared claim:

| Cluster | ReadWriteMany backing | Notes |
| --- | --- | --- |
| EKS | EFS (`efs.csi.aws.com`) | Needs the EFS CSI driver and an access point or StorageClass with `uid` and `gid` 1001. |
| AKS | Azure Files (`file.csi.azure.com`) | Set `uid=1001` and `gid=1001` mount options, as above. |
| GKE | Filestore (`filestore.csi.storage.gke.io`) | The default tier has a 1 TiB minimum; check the tier before sizing. |
| DOKS | None native | Block storage is ReadWriteOnce only. Use `storage.backend=s3` with DigitalOcean Spaces and no staging claim. |

A claim that stays ReadWriteOnce works only while every pod that mounts it lands
on one node. With more than one api or worker replica, NOTES prints a warning.

S3-compatible endpoints (MinIO, R2): raster serving resolves assets as
`/vsis3/` paths. The chart derives GDAL's `AWS_S3_ENDPOINT`, `AWS_HTTPS`, and
`AWS_VIRTUAL_HOSTING` settings from `storage.s3Endpoint`, `s3AllowHttp`, and
`s3AddressingStyle`; an explicit `titiler.extraEnv` entry still overrides a
derived value.

### Azure Blob Storage

With `storage.backend=azure` the api and worker need `AZURE_STORAGE_CONTAINER`
and either `AZURE_STORAGE_CONNECTION_STRING` or `AZURE_STORAGE_ACCOUNT_URL`
plus `AZURE_STORAGE_ACCOUNT_KEY`. The chart Secret has no Azure keys, so keep
the key or connection string in your `secrets.existingSecret` (the api and
worker load every key in it); the container and account URL can go there or
in `api.extraEnv` and `worker.extraEnv`.

Titiler needs credentials of its own, and the chart renders none for azure.
It opens Azure rasters as `/vsiaz/` paths, so GDAL reads its own variables
and ignores the application's. Without them every raster tile fails. GDAL
names the key `AZURE_STORAGE_ACCESS_KEY`, so map the same Secret key onto
that name:

```yaml
titiler:
  extraEnv:
    - name: AZURE_STORAGE_ACCOUNT
      value: <storage-account-name>
    - name: AZURE_STORAGE_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: geolens-secrets
          key: AZURE_STORAGE_ACCOUNT_KEY
```

An account key can also write and delete. For a read-only Titiler, store a
read-only SAS token and pass it as `AZURE_STORAGE_SAS_TOKEN` instead of the
key, at the cost of rotating it before it expires. GDAL wants the token
URL-encoded and without a leading `?` or `&`.

### Keyless object storage (IRSA / Pod Identity)

On EKS you do not need to keep IAM user keys in a Secret at all. Annotate the
chart's ServiceAccount with the role and turn off static keys:

```bash
helm upgrade --install geolens helm/geolens \
  --set storage.backend=s3 \
  --set storage.s3Bucket=geolens \
  --set storage.s3Region=us-east-1 \
  --set storage.s3AmbientCredentials=true \
  --set serviceAccount.create=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::<account>:role/geolens-s3
```

`serviceAccount.create=true` is required here: it defaults to false so that an
upgrade never moves existing workloads off the `default` account, and without
it the annotation is rendered nowhere while this same command removes the
static keys — leaving the pods with no credentials at all.

The api, worker and TiTiler pods then resolve the role themselves — boto3 for
the application, GDAL for TiTiler's `/vsis3/` reads. EKS **Pod Identity** needs
no annotation; associate the role with this ServiceAccount name instead. To
attach a ServiceAccount you manage (eksctl, Terraform), keep
`serviceAccount.create=false` and set `serviceAccount.name`.

Requires app images **≥ 1.14.2** (the chart default from 0.4.26): earlier
backends refuse to boot with `STORAGE_PROVIDER=s3` and no `S3_ACCESS_KEY_ID`,
whatever the runtime offers.

> **Migrating an existing install off static keys:** a key already stored in
> the Secret is **not** removed by upgrading to a keyless configuration if that
> Secret was first written by a chart older than 0.4.25 — those releases wrote
> credentials through `stringData`, which the API server folds into `data`, so
> Helm's deletion diff finds nothing to remove. Both boto3 and GDAL prefer a
> static key over an attached role, so the install keeps using the old
> credential while the rendered manifest looks clean. Remove it once, by hand:
>
> ```bash
> kubectl patch secret <release>-secrets --type=json \
>   -p '[{"op":"remove","path":"/data/S3_ACCESS_KEY_ID"},
>        {"op":"remove","path":"/data/S3_SECRET_ACCESS_KEY"}]'
> kubectl rollout restart deploy/<release>-api deploy/<release>-worker deploy/<release>-titiler
> ```
>
> Restarting TiTiler matters: env vars are read at pod start, so a running
> pod keeps the old key until it is replaced.

### TiTiler read-only S3 credentials

TiTiler never writes objects. Give it a separate principal that can read only
the managed raster prefixes (`rasters/*` and `tenants/*/rasters/*`), store that
principal in an operator-managed Kubernetes Secret, and select it with
`titiler.s3Credentials`. For example, create `geolens-titiler-s3` through your
External Secrets controller or from an operator-protected env file (this keeps
the secret off the Helm command line):

```bash
kubectl create secret generic geolens-titiler-s3 \
  --from-env-file=/secure/path/titiler-s3.env

helm upgrade --install geolens helm/geolens \
  --set secrets.existingSecret=geolens-secrets \
  --set storage.backend=s3 \
  --set storage.s3Bucket=geolens \
  --set titiler.s3Credentials.existingSecret=geolens-titiler-s3 \
  --set titiler.s3Credentials.accessKeyIdKey=AWS_ACCESS_KEY_ID \
  --set titiler.s3Credentials.secretAccessKeyKey=AWS_SECRET_ACCESS_KEY
```

The protected env file contains those two named keys. The chart renders only
the selected Secret references into the TiTiler sidecar; it does not also pass
the shared writer credential. When `titiler.s3Credentials.existingSecret` is
empty, the chart falls back to the main GeoLens Secret and the
`S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` keys, preserving existing installs
while operators migrate.

For MinIO, save this policy as `geolens-titiler-readonly.json`, replacing
`<bucket-name>` with the configured bucket. It grants only `GetObject` under
the single-tenant and tenant-scoped managed-raster layouts:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": [
        "arn:aws:s3:::<bucket-name>/rasters/*",
        "arn:aws:s3:::<bucket-name>/tenants/*/rasters/*"
      ]
    }
  ]
}
```

Create and attach it to a distinct MinIO user, then store that user's generated
credential in the Kubernetes Secret above. Do not put the credential in the
policy file, source control, command arguments, or command output.

```bash
mc admin policy create <alias> geolens-titiler-readonly geolens-titiler-readonly.json
mc admin policy attach <alias> geolens-titiler-readonly --user <titiler-user>
mc admin policy entities <alias> --policy geolens-titiler-readonly
```

## Pod security

Every container meets the Kubernetes Pod Security `restricted` standard: no
privilege escalation, all capabilities dropped, the `RuntimeDefault` seccomp
profile, and a non-root user. The backend pods run as uid 1001 through
`podSecurityContext`, the frontend as nginx's uid 101 through
`frontend.podSecurityContext`, and TiTiler, whose upstream image would
otherwise run as root, as uid 1001 through `titiler.podSecurityContext`. CI
installs the chart into a namespace that enforces `restricted`.

Root filesystems are read-only, as compose runs these images. Each pod gets
emptyDirs for what it writes outside `/app/staging`: `/tmp` and
`/home/appuser` for the api, worker and migrate hook, `/tmp` and
`/var/cache/nginx` (the raster tile cache) for the frontend, and `/tmp` for
TiTiler. A backend component whose `extraVolumeMounts` already mounts `/tmp` or
`/home/appuser` keeps that mount, and the chart skips its own emptyDir there.
CI ingests a vector and a raster dataset under these settings. If
something you add writes elsewhere, `readOnlyRootFilesystem: false` turns it
off for everything but TiTiler.

## Running more than one replica

`api.replicas`, `frontend.replicas` and `titiler.replicas` default to 2.
Beyond one api replica:

- **Storage must be shared.** Use `storage.backend=s3`, or `local`/`azure` with
  a ReadWriteMany `staging.persistence` claim (see the Storage section).
  Otherwise each pod keeps its own private copy.
- **Share one cache.** Set `redis.url` (or a `REDIS_URL` key in
  `secrets.existingSecret`). Without it, rate limits count per replica,
  caches are per process, and importing a token-protected service answers 503.
- **Budget database connections.** Every api and worker replica holds a
  connection pool. Work out the total against your database's
  `max_connections` before adding replicas or enabling an HPA; the formula is
  in [Database connections](../../clouds/README.md#database-connections).
- **Set `frontend.trustedProxyCidrs`.** With several frontend pods behind an
  ingress, nginx still needs the proxy hops listed as `TRUSTED_PROXY_CIDRS` to
  see the real client, or the anonymous raster rate limit lands in one bucket.
- **Shut down gracefully.** The api and frontend sleep in a `preStop` hook
  before draining, and the chart refuses a `terminationGracePeriodSeconds` that
  does not outlast the sleep plus the api's 30-second uvicorn drain. The hook
  runs `sleep`, which both images ship, because the native `preStop.sleep`
  action needs Kubernetes 1.30 and the chart supports 1.21.
- **Spread and roll safely.** Components with no `topologySpreadConstraints`
  get a soft node and zone spread, a value you set replaces it, and the api,
  frontend and TiTiler roll with `maxUnavailable: 0`. The reasons are in
  `values.yaml`.

The chart prints a warning in NOTES whenever `redis.url` is empty, and with
`secrets.existingSecret` it reminds you that the Secret must hold `REDIS_URL`.

### Autoscaling

`api.autoscaling`, `frontend.autoscaling` and `titiler.autoscaling` each render
an `autoscaling/v2` HorizontalPodAutoscaler (`v2beta2` before Kubernetes 1.23)
on CPU when `enabled` is true (`minReplicas`, `maxReplicas`,
`targetCPUUtilizationPercentage`). The cluster needs a metrics server, and the
component needs a CPU request, which the default `resources` provide. While an
HPA is enabled the chart writes back the Deployment's live replica count
instead of `replicas`, so neither `helm upgrade` nor turning the HPA on resets
the count; `minReplicas` takes over as the floor. Turn it off again and
`replicas` returns. `helm template`, which has no cluster to ask, leaves the
field out, so GitOps tools should ignore `spec.replicas` on these Deployments.

### The worker

The worker stays at one replica by default. It takes jobs from a PostgreSQL
queue, so more replicas share the work, subject to the storage rule above.
Each one also adds database connections. A HorizontalPodAutoscaler on CPU fits
it poorly, because queued work is not CPU. A KEDA `ScaledObject` can follow the
queue depth instead. The chart ships no KEDA template; this is a starting point
that assumes a KEDA install and a `ScaledObject` targeting the worker Deployment
with this trigger:

```yaml
triggers:
  - type: postgresql
    metadata:
      query: "SELECT count(*) FROM catalog.procrastinate_jobs WHERE status = 'todo'"
      targetQueryValue: "5"
    authenticationRef:
      name: geolens-keda-postgres   # a TriggerAuthentication holding the connection string
```

Set `worker.autoscaling.enabled=true` while KEDA owns the count. The chart
renders no HPA for the worker; it only stops writing `replicas`, so a
`helm upgrade` leaves KEDA's count alone.
The worker has no PodDisruptionBudget: at one replica `maxUnavailable: 1`
permits the eviction anyway, and a worker finishes or releases its jobs inside
`worker.terminationGracePeriodSeconds`.

### Metrics

`serviceMonitor.enabled=true` renders a Prometheus Operator ServiceMonitor for
the api and a PodMonitor for the worker, whose health port also serves
`/metrics`. They are off by default because both kinds are CRDs; a cluster
without the Operator rejects them. Put the label your Prometheus selects on in
`serviceMonitor.labels`, and with `networkPolicy.enabled` list the Prometheus
pods in `networkPolicy.metricsFrom`.

### Default resources

Chart 0.5.0 sets resource requests and memory limits (values in `values.yaml`),
and TiTiler defaults to two replicas. `helm upgrade --reuse-values` keeps the
empty values of an earlier release; pass `--reset-then-reuse-values` to pick up
the new defaults.

## Placement and disruption

Each of `api`, `worker`, `frontend` and `titiler` takes `nodeSelector`,
`tolerations`, `affinity` and `topologySpreadConstraints`. The migrate hook Job
takes the api's `nodeSelector`, `tolerations` and `affinity.nodeAffinity`, so a
toleration for a dedicated node pool reaches the hook as well; without it the
hook stays `Pending` and the install times out. It does not take the api's pod
affinity or spread constraints, since those select api pods and a pre-install
hook runs before any exist.

PodDisruptionBudgets cover the api, frontend and TiTiler with
`maxUnavailable: 1`, so a node drain evicts one pod of each at a time and never
blocks outright, even at one replica. Turn them off with
`podDisruptionBudget.enabled=false`.

## Network policies

`networkPolicy.enabled=true` adds NetworkPolicies that hold the "everything
through the edge" rule below the ingress too:

- only this release's frontend and TiTiler reach the api, so no other pod can
  route around the edge or hand the api a forged `X-Forwarded-For`. TiTiler
  reads remote (STAC) rasters through the api's internal relay route, at
  `REMOTE_RASTER_RELAY_BASE_URL`, which the chart sets to the api Service;
- only the api reaches TiTiler;
- nothing reaches the worker.

`networkPolicy.metricsFrom` lists the peers allowed to scrape `/metrics` on
the api and worker, for example your monitoring namespace. The api serves
`/metrics` on its only port and a NetworkPolicy cannot filter paths, so those
peers can call every api route directly, skipping the edge, and set their own
`X-Forwarded-For`. Treat them as trusted API clients.
`networkPolicy.frontendFrom` restricts the frontend to the peers you list,
typically the ingress controller's namespace; left empty, the frontend stays
open to the cluster. Egress is not restricted, and kubelet probes are never
blocked.

The policies are off by default because they need a CNI that enforces them.
They were verified on Calico. kind's default kindnet drops the replies to a
policy-selected pod's own DNS lookups
([kube-network-policies#379](https://github.com/kubernetes-sigs/kube-network-policies/issues/379)),
so on kindnet the api and worker cannot reach the database; CI runs on Calico
for that reason.

## Database requirements

The externally managed PostgreSQL instance must satisfy:

- **PostgreSQL 15+** — the schema uses `NULLS NOT DISTINCT` unique indexes. The
  baseline migration aborts below 15 with `GeoLens requires PostgreSQL 15+
  (NULLS NOT DISTINCT unique indexes)`.
- **pgvector 0.5+** — semantic search uses an HNSW index (baseline migration); older
  pgvector fails with `access method "hnsw" does not exist`.
- **Extensions present**: `postgis`, `pg_trgm`, `vector` (pgvector), `unaccent`.
  On managed services (RDS, Cloud SQL) create them once with a privileged role,
  e.g. `CREATE EXTENSION IF NOT EXISTS vector;`.
- **Schemas and reader role pre-created** — the migrations expect them (the
  hook otherwise fails with `schema "data" does not exist`). Run once with a
  privileged role, where `app_user` is the role from your
  `DATABASE_URL_OVERRIDE` DSN — the `AUTHORIZATION` clause matters on managed
  services (RDS, Cloud SQL): schemas owned by the admin role would leave the
  app user without `USAGE`/`CREATE` and the migration job fails on permission
  errors:

  ```sql
  CREATE SCHEMA IF NOT EXISTS catalog AUTHORIZATION app_user;
  CREATE SCHEMA IF NOT EXISTS data AUTHORIZATION app_user;
  CREATE ROLE geolens_reader NOLOGIN;
  GRANT USAGE ON SCHEMA data TO geolens_reader;
  GRANT SELECT ON ALL TABLES IN SCHEMA data TO geolens_reader;
  ALTER DEFAULT PRIVILEGES FOR ROLE app_user IN SCHEMA data
    GRANT SELECT ON TABLES TO geolens_reader;
  ```

### Database TLS

Set `database.sslMode` (`disable` | `prefer` | `require` | `verify-full`).
Leaving it empty keeps the application default, `prefer`, which uses encryption
when the server offers it and **silently continues without it when it does
not**.

> Writing `?sslmode=require` into `secrets.databaseUrlOverride` does **not**
> configure TLS. The backend strips that parameter before handing the DSN to
> asyncpg, which has no such option, and derives TLS from `database.sslMode`
> alone. Verified against RDS: with `sslmode=require` in the DSN and the mode
> set to `disable`, the client offered no encryption and only the server's own
> `rds.force_ssl` refused the connection.

`verify-full` additionally needs the provider's CA bundle as a file. Create a
ConfigMap for it and mount it into all three workloads that talk to the
database — the migrate hook included, or the upgrade fails there before any pod
rolls:

```bash
curl -o rds-ca.pem https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem
kubectl create configmap rds-ca --from-file=rds-ca.pem
```

```yaml
database:
  sslMode: verify-full
extraVolumes:
  - name: rds-ca
    configMap:
      name: rds-ca
api:
  extraEnv: [{name: DATABASE_SSL_CA_CERT, value: /etc/ssl/db/rds-ca.pem}]
  extraVolumeMounts: [{name: rds-ca, mountPath: /etc/ssl/db, readOnly: true}]
worker:
  extraEnv: [{name: DATABASE_SSL_CA_CERT, value: /etc/ssl/db/rds-ca.pem}]
  extraVolumeMounts: [{name: rds-ca, mountPath: /etc/ssl/db, readOnly: true}]
migrate:
  # extraEnv is not repeated here: the migrate Job already renders
  # api.extraEnv. Setting the same name in both is safe (the migrate value
  # wins, and the chart drops the duplicate), but there is nothing to gain.
  # The MOUNT is not shared, so that one does have to be repeated.
  extraVolumeMounts: [{name: rds-ca, mountPath: /etc/ssl/db, readOnly: true}]
```

`verify-full` needs app images **≥ 1.14.2** on any deployment that ingests
vector data: earlier builds passed the TLS mode to `ogr2ogr` without the CA
path, so every vector ingest failed inside libpq with `root certificate file
... does not exist` while the API itself stayed healthy.

## Backups

The chart ships no backup workload. The Docker Compose stack's `backup`
service (scheduled `pg_dump`, local retention, optional offsite S3 upload)
is Compose-only: it dumps the bundled `db` container, and this chart does
not install PostgreSQL. On Kubernetes, database recovery belongs to your
externally managed PostgreSQL — use its native backup/PITR. If you enable
`staging.persistence`, cover that PVC with your volume-snapshot tooling;
uploaded source files live there. Restore procedures are in the main repo's
[RUNBOOK.md](https://github.com/geolens-io/geolens/blob/main/RUNBOOK.md)
(section 3, managed / external Postgres mode).

## Migrations and upgrades

Migrations run in a `pre-install,pre-upgrade` hook Job, so new pods only start
against a migrated schema and repeated `helm upgrade`s never trip Kubernetes'
immutable-Job rule. The api pods skip their own boot-time migration while the
hook is enabled (`migrate.enabled=true`, the default). Extra env for the hook
(e.g. `DATABASE_SSL_MODE`) follows `api.extraEnv` and `migrate.extraEnv`.

Without `secrets.existingSecret`, the Job reads its credentials from a hook
Secret, `<release>-migrate-secrets`, created just before it. Helm deletes
both once every pre-install or pre-upgrade hook has succeeded, and Argo CD
once the whole sync has. After a failed hook, Helm 3.19 or later and Helm 4
delete the Secret and keep the Job for its logs; older Helm 3 and Argo CD
keep both until the next upgrade or sync replaces them. `helm uninstall`
never removes hook resources, so delete a leftover
`<release>-migrate-secrets` or `<release>-migrate` by hand.

To upgrade GeoLens: bump the three `ghcr.io/geolens-io/*` image tags (they
track GeoLens releases; a weekly CI check flags drift) and `helm upgrade`.

Upgrading to 1.22.0 from an earlier release: file replacements use a new
worker task. A replacement submitted while a worker from the previous release
is still running can fail as an unknown task. Nothing is published when that
happens, so submit the replacement again once every worker runs 1.22.0.

Upgrading to 1.23.0: importing, re-uploading or refreshing a service that
needs a token now requires `redis.url` to point at a Valkey or Redis instance
that the api and worker share. Without one those requests answer 503
`credential_store_unavailable`. Services without a token are unaffected.

Upgrading to 1.25 (1.25.1 is the first release with api and worker images):

- **Give the migration hook more time.** Migration 0083 builds its indexes
  on `ingest_jobs` and `records` with `CREATE INDEX CONCURRENTLY`, which
  waits for open transactions to finish before and during the build, and
  the build itself takes longer on a large catalog. Helm gives each hook the
  `--timeout` of the upgrade, 5 minutes by default, so run this upgrade with
  something like `helm upgrade --timeout 30m`. On a timeout Helm marks the
  upgrade failed and leaves the previous pods serving, while the Job keeps
  running in the cluster. Upgrade again: `before-hook-creation` replaces the
  old Job, and 0083 drops and rebuilds the invalid index an interrupted build
  leaves behind.
- **Cloudflare Web Analytics.** The frontend's default CSP no longer allows
  Cloudflare's beacon script. On a Cloudflare-proxied install with Web
  Analytics on, add it back through `frontend.extraEnv`:

  ```yaml
  frontend:
    extraEnv:
      - name: CSP_SCRIPT_SRC_EXTRA
        value: https://static.cloudflareinsights.com
  ```

  Use the host, not the `beacon.min.js` path. Cloudflare loads
  `beacon.min.js/v<hash>`, and a CSP source naming a file matches only that
  exact path, so the browser would still block the script.
- **Private certificate authorities.** Outbound TLS from the AI providers and
  the OAuth client now checks the operating system trust store instead of
  certifi. With the read-only root filesystem you cannot add a CA to the
  image's store, so mount a bundle that holds the system CAs plus yours (a
  ConfigMap in `extraVolumes`, mounted through `api.extraVolumeMounts` and
  `worker.extraVolumeMounts`) and point `SSL_CERT_FILE` at it in
  `api.extraEnv` and `worker.extraEnv`.
- **Sign-in lockout.** After 10 failed password sign-ins within an hour, an
  account answers 429 to browsers it doesn't know, even with the right
  password. To let an admin back in from a new browser, run
  `kubectl exec deploy/<release>-api -- /app/.venv/bin/python -m scripts.trust_login_device <username>`
  (add `--tenant <tenant id>` on a multi-tenant install). It prints a link
  that works once, within 10 minutes. Section 12 of the GeoLens
  [RUNBOOK](https://github.com/geolens-io/geolens/blob/main/RUNBOOK.md) lists
  the other ways back in.

Upgrading to 1.26.0: migrations 0084 to 0086 are additive. 0085 waits at most
5 seconds for its lock on `catalog.datasets` instead of queueing behind other
writes, so on a busy catalog the migrate hook can fail with a lock timeout.
Helm then marks the upgrade failed and keeps the previous pods serving. Run
the upgrade again.

## Render locally

The values below are placeholders for a template render, not credentials.

```bash
helm template geolens helm/geolens \
  --set secrets.databaseUrlOverride='postgresql+asyncpg://geolens:change-me@postgres/geolens' \
  --set secrets.jwtSecretKey="$(openssl rand -hex 32)" \
  --set secrets.adminUsername=admin \
  --set secrets.adminPassword='a-strong-unique-password'
```

## License

Apache-2.0, the same license as GeoLens. See [LICENSE](../../LICENSE).
