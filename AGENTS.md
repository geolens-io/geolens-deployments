# Repository Guidelines

Infrastructure only. This repo packages [GeoLens](https://github.com/geolens-io/geolens)
for Kubernetes and AWS. No application code lives here.

## Project Structure & Module Organization

`helm/geolens/` is the chart. `Chart.yaml` carries `version` and `appVersion`,
`values.yaml` documents every value inline, and `templates/` holds:

- `_helpers.tpl`: name, fullname, label, secret-name and ServiceAccount-name helpers.
- `configmap.yaml`: non-secret app env (`ENVIRONMENT`, public URLs, `STORAGE_PROVIDER`, S3 settings, `DATABASE_SSL_MODE`).
- `secret.yaml`: chart-managed Secret, rendered only when `secrets.existingSecret` is empty.
- `serviceaccount.yaml`: optional ServiceAccount for IRSA / Pod Identity.
- `api-deployment.yaml`, `worker-deployment.yaml`, `frontend-deployment.yaml`, `titiler-deployment.yaml`: the four workloads.
- `service-api.yaml`, `service-frontend.yaml`, `service-titiler.yaml`: their Services.
- `migrate-job.yaml`: Alembic `upgrade heads` as a pre-install/pre-upgrade hook.
- `staging-pvc.yaml`: optional shared `/app/staging` claim.
- `ingress.yaml`: single route, everything to the frontend edge.
- `NOTES.txt`: post-install URL plus warnings for old frontend tags and disabled staging persistence.

`examples/` holds values files to adapt (`values-aws.yaml`, an EKS install).
`terraform/aws-ecs-fargate/` is a root module: ECS Fargate, RDS PostgreSQL, S3,
ElastiCache Valkey, ALB. `terraform fmt -check` and `terraform validate` are its
gates. A real apply needs an AWS profile, and the migrate step runs a one-shot
ECS task through `aws ecs run-task` from a `local-exec` provisioner.

`.github/ci/postgres.yaml` is a CI-only PostGIS + pgvector deployment for the
kind test. It is not a production manifest.

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

terraform -chdir=terraform/aws-ecs-fargate fmt -check
terraform -chdir=terraform/aws-ecs-fargate init -backend=false && \
  terraform -chdir=terraform/aws-ecs-fargate validate
```

`helm lint` does not enforce `required`, so lint with the same values the
template matrix uses.

### What CI runs

`ci.yml` (push to main, and every PR) has three jobs. `lint-and-template` lints,
renders three configurations (defaults; `existingSecret` + ingress + staging
persistence; Titiler disabled + S3), then runs guards that each pin a bug that
rendering alone would not catch: Titiler picks exactly one S3 credential source
and quotes scalar-looking Secret selectors; the migrate hook sets no
`serviceAccountName` while api/worker/titiler all do; the Secret renders `data`
and not `stringData`; `s3AmbientCredentials` emits no static keys while the
static path still fails closed without them; rendering survives
`serviceAccount=null` and `database=null` (a cross-version `--reuse-values`
upgrade); `database.sslMode` reaches both the ConfigMap and the migrate hook;
no `GDAL_HTTP_FOLLOWLOCATION` appears anywhere; an empty install fails;
`GDAL_VRT_RAWRASTERBAND_ALLOWED_SOURCE` holds a token GDAL accepts; and
`extraEnv` overrides render exactly once per container and win; the api
liveness probe is `/health/live` while readiness stays `/health`; and the
stored-secret encryption keys reach both the Secret and the migrate hook while
a previous key without a current one, or a key against an api or worker tag
older than 1.18.2, fails to render.

`install-test` needs that job, creates a kind cluster, applies
`.github/ci/postgres.yaml`, runs `helm install --wait` at the chart's default
tags, curls `http://geolens-frontend/api/health` from a pod, then runs
`helm upgrade --reuse-values --wait` to re-exercise the migrate hook.

`terraform-validate` runs `terraform fmt -check -recursive` and
`terraform init -backend=false && terraform validate` in
`terraform/aws-ecs-fargate`. It never touches an AWS account.

`release-charts.yml` runs on pushes to `main` under `helm/**` and on
`workflow_dispatch`. `version-drift.yml` runs weekly (Mondays 06:17 UTC) and on
dispatch.

## Versioning

- Bump `Chart.yaml` `version` for every chart change that should be released. Landing that bump on `main` is what cuts the release: `release-charts` packages the chart with chart-releaser, attaches it to a GitHub Release, updates `gh-pages`, and pushes the same package to `ghcr.io/geolens-io/charts/geolens`. Both legs probe first, so a rerun or a non-bump edit under `helm/` republishes nothing.
- `appVersion`, the three `ghcr.io/geolens-io/*` tags in `values.yaml`, and the `geolens_version` default in `terraform/aws-ecs-fargate/variables.tf` track GeoLens releases and move together. `version-drift` fails when any of them is behind the latest GeoLens release.
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
- Every new top-level values map must be dereferenced through `| default dict`. A `--reuse-values` upgrade from a release installed before the map existed supplies nothing, and a bare dereference aborts rendering.
- The Secret renders `data` with `b64enc`, never `stringData`, or removed keys survive `helm upgrade`.
- The ingress routes everything to the frontend edge. Do not add a path that reaches the api directly; that bypasses the metrics block, the anonymous raster rate limit, and log redaction.
- Add a CI guard for anything a render can pass while a real cluster fails.

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
