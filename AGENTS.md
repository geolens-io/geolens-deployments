# Repository Guidelines

Infrastructure only. This repo packages [GeoLens](https://github.com/geolens-io/geolens)
for Kubernetes, AWS and Azure. No application code lives here.

## Project Structure & Module Organization

`helm/geolens/` is the chart. `Chart.yaml` carries `version` and `appVersion`,
`values.yaml` documents every value inline, and `templates/` holds:

- `_helpers.tpl`: name, fullname, label, secret-name and ServiceAccount-name helpers, plus the shared container security context, scratch volumes, and per-component placement.
- `configmap.yaml`: non-secret app env (`ENVIRONMENT`, public URLs, `STORAGE_PROVIDER`, S3 settings, `DATABASE_SSL_MODE`).
- `secret.yaml`: chart-managed Secret, rendered only when `secrets.existingSecret` is empty.
- `serviceaccount.yaml`: optional ServiceAccount for IRSA / Pod Identity.
- `api-deployment.yaml`, `worker-deployment.yaml`, `frontend-deployment.yaml`, `titiler-deployment.yaml`: the four workloads.
- `service-api.yaml`, `service-frontend.yaml`, `service-titiler.yaml`: their Services.
- `migrate-job.yaml`: Alembic `upgrade heads` as a pre-install/pre-upgrade hook.
- `staging-pvc.yaml`: optional shared `/app/staging` claim.
- `ingress.yaml`: single route, everything to the frontend edge.
- `pdb.yaml`: PodDisruptionBudgets (`maxUnavailable: 1`) for the api, frontend and titiler.
- `networkpolicy.yaml`: opt-in NetworkPolicies; only the frontend reaches the api, only the api reaches titiler.
- `NOTES.txt`: post-install URL plus warnings for old frontend and api tags and for `storage.backend=local` without staging persistence.

`examples/` holds values files to adapt (`values-aws.yaml`, an EKS install).
`terraform/aws-ecs-fargate/` is a root module: ECS Fargate, RDS PostgreSQL, S3,
ElastiCache Valkey, ALB. `terraform fmt -check` and `terraform validate` are its
gates. A real apply needs an AWS profile, and the migrate step runs a one-shot
ECS task through `aws ecs run-task` from a `local-exec` provisioner.
`terraform/azure-container-apps/` is the Azure counterpart: Container Apps,
PostgreSQL Flexible Server, Blob Storage plus an Azure Files share for
`/app/staging`, and optional Azure Managed Redis. Its migrate step starts a
Container Apps job through `az containerapp job start`, and its `migrate.py`
also lends the tenant provisioner role what a non-superuser migrator needs.

`clouds/` is prose, one page per cloud, covering the managed database, bucket
and cache a deployment sits on plus that cloud's environment deltas. It is the
manual counterpart to the recipe for the same cloud, so keep the two in step.
Provider-neutral material stays on the docs site.

`.github/ci/postgres.yaml` is a CI-only PostGIS + pgvector deployment for the
kind test. It is not a production manifest. `.github/ci/kind-calico.yaml`
creates that cluster without kindnet, `ingest-smoke.sh` pushes a vector file and
`smoke.tif` through a running install's edge and fetches a raster tile, and
`.github/dependabot.yml` keeps the SHA-pinned actions and the Terraform
providers current.

## Build, Test, and Validate Commands

```bash
helm lint helm/geolens \
  --set secrets.databaseUrlOverride='postgresql+asyncpg://geolens:pw@db.internal:5432/geolens' \
  --set secrets.jwtSecretKey='0123456789abcdef0123456789abcdef' \
  --set secrets.adminUsername='admin' --set secrets.adminPassword='chart-ci-only-Passw0rd!'

helm template geolens helm/geolens \
  --set secrets.databaseUrlOverride='postgresql+asyncpg://geolens:change-me@postgres/geolens' \
  --set secrets.jwtSecretKey="$(openssl rand -hex 32)" \
  --set secrets.adminUsername=admin --set secrets.adminPassword='a-strong-unique-password'

terraform fmt -check -recursive terraform
for dir in terraform/*/; do
  terraform -chdir="$dir" init -backend=false && terraform -chdir="$dir" validate
done
```

`helm lint` does not enforce `required`, so lint with the same values the
template matrix uses.

### What CI runs

`ci.yml` (push to main, and every PR) has three jobs. The two chart jobs run
once per pinned Helm version, 3 and 4.
`main` requires five of these checks by name: `lint-and-template (helm 3)`,
`lint-and-template (helm 4)`, `kind install test (helm 3)`,
`kind install test (helm 4)` and `terraform validate`. Bumping a pinned Helm
version keeps those names. Renaming a job or adding a Helm major changes them,
so update the branch protection rule in the same change.

`lint-and-template` lints, renders three configurations (defaults;
`existingSecret` + ingress + staging persistence; Titiler disabled + S3), then
runs guards that each pin a bug rendering alone would not catch:

- Titiler picks exactly one S3 credential source and quotes scalar-looking Secret selectors.
- The migrate hook sets no `serviceAccountName`, while api/worker/titiler all do.
- The Secret renders `data`, not `stringData`.
- `s3AmbientCredentials` emits no static keys, and the static path still fails closed without them.
- Rendering survives `serviceAccount=null` and `database=null`, and the templates rendered against the latest published chart's `values.yaml` (what `--reuse-values` renders against) still run titiler and the frontend non-root, every container read-only, with three PDBs.
- `database.sslMode` reaches both the ConfigMap and the migrate hook.
- NetworkPolicies render only when enabled, and the api's admits only the frontend.
- Each component's placement reaches its pods. The migrate hook takes the api's nodeSelector, tolerations and node affinity, and never its pod affinity or spread constraints.
- Operator `extraVolumes` named `tmp` or `home`, or a component mount at `/tmp` or `/home/appuser`, never repeat a volume name or mountPath in the api, worker or migrate pod. An operator volume named `geolens-tmp` or `geolens-home` and mounted elsewhere fails the render.
- No `GDAL_HTTP_FOLLOWLOCATION` appears anywhere, and `GDAL_VRT_RAWRASTERBAND_ALLOWED_SOURCE` holds a token GDAL accepts.
- An empty install fails.
- `extraEnv` overrides render exactly once per container and win.
- All three api probes are `/health/live`; the api sets `FORWARDED_ALLOW_IPS` once and an `extraEnv` value replaces it.
- The stored-secret encryption keys reach both the Secret and the migrate hook, while a previous key without a current one, or a key against an api or worker tag older than 1.18.2, fails to render.

`install-test` needs that job. It creates a kind cluster on Calico (kindnet's
policy engine breaks DNS for policy-selected pods), applies
`.github/ci/postgres.yaml`, and runs `helm install --wait` at the chart's
default tags into a `geolens` namespace that enforces Pod Security
`restricted`, with the NetworkPolicies on and a shared staging claim. It curls
`http://geolens-frontend.geolens/api/health` from a pod, runs `ingest-smoke.sh`
through a port-forward, checks that a pod outside the release reaches the
frontend but not the api, titiler or worker, then runs
`helm upgrade --reuse-values --wait` to re-exercise the migrate hook.

`terraform-validate` runs `terraform fmt -check -recursive` over `terraform/`,
`terraform init -backend=false && terraform validate` in every recipe, and
`test-pilot-profile.sh` in `terraform/aws-ecs-fargate`. It never touches a cloud
account.

`release-charts.yml` runs when `chart-ci` succeeds on a push to `main`, from
the commit CI tested, and on `workflow_dispatch` from `main`. It signs each OCI
chart it pushes with keyless cosign. Every run checks the current `Chart.yaml`
version in GHCR: it pushes and signs a missing one, signs an unsigned one only
when its files match the tested commit's package, fails on any other registry
error, and verifies the signature anonymously.
`version-drift.yml` runs weekly (Mondays 06:17 UTC) and on dispatch.

## Versioning

- Bump `Chart.yaml` `version` for every chart change that should be released. Landing that bump on `main` is what cuts the release: once `chart-ci` passes on that push, `release-charts` packages the tested commit with chart-releaser, attaches it to a GitHub Release, updates `gh-pages`, and pushes the same package to `ghcr.io/geolens-io/charts/geolens`, signed with keyless cosign. Both legs probe first, so a rerun or a merge without a version bump republishes nothing.
- `appVersion`, the three `ghcr.io/geolens-io/*` tags in `values.yaml`, and the `geolens_version` default in each recipe's `variables.tf` track GeoLens releases and move together. `version-drift` fails when any of them is behind the latest GeoLens release.
- The `ghcr.io/developmentseed/titiler` tag is bumped deliberately, not on a schedule. Upstream ships security fixes as ordinary bugfix releases with no advisory (geolens#1190).

## Conventions

Values are documented in `values.yaml` with the reasoning for the default, not
just the meaning. Keep that when adding one.

Comments in templates follow the core repo's inline review-comment convention:
anchor to a PR or issue that can be looked up (`codex review on #29`,
`geolens#1191`) plus the invariant the code now holds, three lines at most. The
history behind it belongs in the PR or issue the anchor names.

- Every generated env entry is skipped when the operator already set that name in `extraEnv`. Build an override-name set first and guard each static entry against it. Duplicate env names break strategic-merge tooling, which keys `env` by `name`, so an Argo or Helm upgrade can fail before a pod rolls.
- The migrate Job is a pre-install/pre-upgrade hook and must reference no chart-created resource. No `serviceAccountName`, no `secretRef` to the chart Secret, no ConfigMap `envFrom`. Values it needs are inlined. It also carries `hook-delete-policy: before-hook-creation,hook-succeeded`, without which Job immutability fails every upgrade.
- `serviceAccount.create` defaults to false on purpose: flipping an existing install to a fresh account would silently drop the `default` account's imagePullSecrets, RBAC, and annotations.
- Every new top-level values map must be dereferenced through `| default dict`. A `--reuse-values` upgrade from a release installed before the map existed supplies nothing, and a bare dereference aborts rendering. A new value whose default matters (a security context, a grace period) needs the same default in the template, or reused-value upgrades silently skip it.
- The Secret renders `data` with `b64enc`, never `stringData`, or removed keys survive `helm upgrade`.
- Every container stays within Pod Security `restricted` (`geolens.containerSecurityContext` plus a non-root user); `install-test` enforces it, so a new container or hook fails CI rather than a hardened cluster.
- The ingress routes everything to the frontend edge. Do not add a path that reaches the api directly; that bypasses the metrics block, the anonymous raster rate limit, and log redaction.
- Add a CI guard for anything a render can pass while a real cluster fails.
- Pin every workflow action to a full commit SHA with its version in a trailing comment (`# v4.4.0`); Dependabot updates both. Helm versions in `setup-helm` inputs are pinned by hand.

## Commit & Pull Request Guidelines

Conventional-commit-like, imperative subject with a scope, for example
`chore(chart): bump to 0.4.33 for GeoLens 1.18.1` or
`chart 0.4.25: ServiceAccount, keyless S3, database TLS, removable secrets`.
Say what changed in the rendered output, and name the cluster or account a
change was validated against when it was.

## Security & Configuration Tips

Never commit secrets, kubeconfigs, `.tfvars` with real values, or Terraform
state. Example files carry `<placeholder>` values only, and `values-aws.yaml`
deliberately points at an `existingSecret` instead of holding a DSN. Keep
credentials off Helm command lines; use a pre-created Secret. The backend
refuses to boot on known-public example passwords, so a leaked demo credential
cannot be reintroduced as a default. Report a chart or recipe vulnerability to
security@getgeolens.com rather than opening a public issue.
