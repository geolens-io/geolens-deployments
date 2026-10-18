# Repository Guidelines

Infrastructure for [GeoLens](https://github.com/geolens-io/geolens): a Helm
chart, Terraform recipes for AWS and Azure, and a provisioning guide per cloud.
No application code lives here; application conventions live in the core
repository's `AGENTS.md`. Keep `CLAUDE.md` as only `@AGENTS.md`, and keep this
file to actionable conventions and traps, linking to the source for detail.

## Project map

- `helm/geolens/`: the chart. `values.yaml` gives the reason for every default that is not obvious.
- `terraform/aws-ecs-fargate/`, `terraform/azure-container-apps/`: one root-module recipe per cloud. Each README covers what it deploys, upgrades, cost, teardown and a "Validated" record. `terraform/README.md` holds the real-account validation procedure.
- `clouds/`: one provisioning guide per cloud, and for AWS and Azure the manual counterpart of the recipe. Change a recipe and its page together; provider-neutral material belongs on the docs site.
- `.github/ci/`: CI fixtures and scripts. `postgres.yaml` is not a production manifest. `ingest-smoke.sh <url> <user> <password>` pushes a vector and a raster through any running install's edge and fetches a tile. `sweep-aws.sh` and `sweep-azure.sh` list what a destroyed recipe stack left behind: `LEFT` lines are that stack's by exact evidence, `NOTE` lines are possible matches to confirm before deleting. `test-sweeps.sh` runs both against stub CLIs.

## Commands and verification

```bash
helm lint helm/geolens \
  --set secrets.databaseUrlOverride='postgresql+asyncpg://geolens:pw@db.internal:5432/geolens' \
  --set secrets.jwtSecretKey='0123456789abcdef0123456789abcdef' \
  --set secrets.adminUsername='admin' --set secrets.adminPassword='chart-ci-only-Passw0rd!'

helm template geolens helm/geolens \
  --set secrets.databaseUrlOverride='postgresql+asyncpg://geolens:change-me@postgres/geolens' \
  --set secrets.jwtSecretKey="$(openssl rand -hex 32)" \
  --set secrets.adminUsername=admin --set secrets.adminPassword='a-strong-unique-password'

bash .github/ci/upgrade-note-parity.sh
bash .github/ci/test-sweeps.sh
terraform fmt -check -recursive terraform
for dir in terraform/*/; do
  terraform -chdir="$dir" init -backend=false && terraform -chdir="$dir" validate
done
bash terraform/aws-ecs-fargate/test-pilot-profile.sh
bash terraform/azure-container-apps/test-validations.sh
```

- `helm lint` does not enforce `required`, so lint with the same values the template command uses.
- Each guard in `ci.yml` is plain shell, named for the invariant it pins. Run the ones that cover what you change.
- A NOTES change needs the kind job: Helm 3 renders NOTES only in a dry run, and that needs a cluster.
- Documentation-only edits need link and command checks, `upgrade-note-parity.sh` when they touch an upgrade note, and `git diff --check`, not the whole matrix.
- Never loosen a guard, pattern or CI job to get a pass. Report failed or unrun checks accurately.

## CI, branch protection and releases

- `main` requires five checks by name: `lint-and-template (helm 3)`, `lint-and-template (helm 4)`, `kind install test (helm 3)`, `kind install test (helm 4)` and `terraform validate`. Bumping a pinned Helm version keeps the names. Renaming a job or adding a Helm major changes them, so update the branch protection rule in the same change. A new check goes into one of these jobs, or it never gates a merge.
- `lint-and-template` renders three configurations and runs guards that each pin a bug rendering alone would not catch. Add a guard for anything a render can pass while a real cluster fails.
- `kind install test` installs at the chart's default tags into a namespace enforcing Pod Security `restricted`, with NetworkPolicies on and a shared staging claim. It ingests through the edge, checks that only the frontend answers pods outside the release, re-runs the migrate hook with `--reuse-values`, and upgrades a separate install from the latest published chart with `--reset-then-reuse-values`. It runs Calico because kindnet's policy engine breaks DNS for policy-selected pods.
- `terraform validate` checks that every chart upgrade note reaches the recipes and cloud guides, tests the sweep scripts against stub CLIs, then runs `fmt`, `init -backend=false` and `validate` in every recipe and both recipe test scripts. It never touches a cloud account.
- `release-charts.yml` publishes after `chart-ci` passes on a push to `main`: a GitHub Release, the `gh-pages` index, and a cosign-signed OCI package in GHCR. It never republishes an existing version, and a rerun or the next green push finishes a release that stopped before signing, so never package or push a chart by hand.
- `version-drift.yml` runs Mondays at 06:17 UTC and fails while `appVersion`, a `ghcr.io/geolens-io/*` tag in `values.yaml` or a recipe's `geolens_version` default differs from the latest GeoLens release.

## Versioning

- Bump `Chart.yaml` `version` for every chart change that should be released. Landing that bump on `main` is the release.
- At a GeoLens release, `appVersion` and the three `ghcr.io/geolens-io/*` tags in `values.yaml` move together with a chart version bump. The kind job exercises the new images.
- Each recipe's `geolens_version` default moves later, in its own PR, after a real-account upgrade of that recipe to the new release. Move the default in `variables.tf` and the `*.tfvars.example` files together, with the README's pinned RUNBOOK links and version-specific text. `version-drift` fails each Monday until both recipes catch up.
- The `ghcr.io/developmentseed/titiler` tag is bumped deliberately, not on a schedule: upstream ships security fixes as ordinary bugfix releases with no advisory.
- Each recipe pins its Terraform providers to exact versions, and Dependabot moves the pins. Given a range, Dependabot's lock-file update resolves the newest version the range allows, which skips the 7-day cooldown in `dependabot.yml`.
- Pin every workflow action to a full commit SHA with its version in a trailing comment (`# v4.4.0`); Dependabot updates both. Pin manifests and images CI fetches to a commit or digest. Helm versions in `setup-helm` inputs are pinned by hand.

## Chart conventions

- Document each new value in `values.yaml` with the reason for its default, not only its meaning.
- Every generated env entry is skipped when the operator already set that name in `extraEnv`: build an override-name set first and guard each static entry against it. Duplicate env names break strategic-merge tooling, which keys `env` by `name`, so an Argo or Helm upgrade can fail before a pod rolls.
- The migrate Job is a pre-install/pre-upgrade hook and must reference no chart-created resource: no `serviceAccountName`, no `secretRef` to the chart Secret, no ConfigMap `envFrom`. Its credentials come from `migrate-secret.yaml`, a hook Secret weighted below the Job (Helm breaks equal weights by name, which puts the Job first); other values it needs are inlined, never a credential. Both carry `hook-delete-policy: before-hook-creation,hook-succeeded`, without which Job immutability fails every upgrade. On success Helm and Argo CD delete `hook-succeeded` hooks only after the whole event or sync, so the Secret outlives the Job's run. When the Job's hook fails or times out, Helm 3.19+ and 4 delete the Secret right away while the Job may still be running, so a retried pod can't start until the next upgrade replaces the Job.
- `serviceAccount.create` defaults to false on purpose: flipping an existing install to a fresh account would silently drop the `default` account's imagePullSecrets, RBAC and annotations.
- Dereference every new top-level values map through `| default dict`. A `--reuse-values` upgrade from a release that predates the map supplies nothing, and a bare dereference aborts rendering. A new value whose default matters, such as a security context or a grace period, needs the same default in the template, or reused-value upgrades silently skip it.
- The Secret renders `data` with `b64enc`, never `stringData`, or removed keys survive `helm upgrade`.
- Every container stays within Pod Security `restricted` (`geolens.containerSecurityContext` plus a non-root user). The kind job enforces it, so a new container or hook fails CI rather than a hardened cluster.
- The ingress routes everything to the frontend edge. Never add a path that reaches the api directly; it would bypass the metrics block, the anonymous raster rate limit and log redaction.
- An upgrade note in the chart README ("Upgrading to X") is carried into both recipe READMEs and both cloud guides in each file's terms. `.github/ci/upgrade-note-parity.sh` enforces it; a chart-only note goes in its `chart_only` list with the reason.

## Recipe conventions

- One root module per cloud, with no registry modules. A `# ponytail:` comment marks each deliberate shortcut and names its ceiling.
- Set a value only when the image's default is wrong for the deployment (`ENVIRONMENT`, `DATABASE_SSL_MODE`, `TILE_BASE_URL`) or another part of the recipe depends on it (the staging mount path, the timeout the worker's stop window is sized for). Leave the rest to the image, lists above all. GeoLens's compose files pin many defaults, but they ship with the app; a copy here goes stale when GeoLens changes it, which is how a pinned `WORKER_QUEUES` once stranded URL imports.
- `extra_env` and `extra_secrets` reserve only the names the recipe must own, listed once as `reserved_env` in `variables.tf`: its generated secrets, its own machinery, and values another container or resource depends on, such as a URL the frontend edge also receives. Ordinary defaults like `ENVIRONMENT`, `LOG_JSON` and `CORS_ALLOWED_ORIGINS` stay overridable. Add a name only when overriding it would break the recipe.
- An input that passes `terraform plan` but fails partway through `apply` gets a variable validation and a case in the recipe's test script. Providers skip their own checks on nested sets while any value is unknown, which is always the case on a first apply.
- Validate on a real account any change to what an apply creates or to the settings a container ends up with, and every move of a `geolens_version` default. Follow "Validating a recipe change" in `terraform/README.md`: an in-place upgrade from a scratch copy, a destroy, and a clean sweep. Record the run in the recipe README's "Validated" section and in the PR.
- Comments, docs, tests and variable validations need only the local checks. So does dropping a setting the pinned image already defaults to, once every reader of it (settings, entrypoints, the frontend bundle) is shown to resolve the same value in that image. Provider bumps within a major version merge on CI and the next real-account run exercises them; a new major gets its own run.

## Comments

- Comments state the current reason or constraint. Remove ones that repeat the code.
- Keep provenance in Git history, issues and PRs. Do not tag comments with PR or issue numbers, review rounds or agent names; keep a reference only when it supplies context the comment cannot state, such as an upstream bug that still applies. Drop older anchors when you touch those lines.
- Keep functional annotations such as `# nosemgrep` and `# ponytail:` with their reasons.
- Template comments stay within three lines.

## Commits and pull requests

- Use scoped Conventional Commits with an imperative subject, such as `fix(chart): 0.4.39 warns that storage.backend=azure needs a shared staging volume`, and a DCO sign-off (`git commit -s`).
- Say what changed in the rendered output, and name the cluster or account a change was validated against.
- A PR description has Summary, Evidence (before and after, for a bug) and Merge Danger (door and blast radius) sections. PRs are squash-merged.

## Code review rules

Reviewers, the Codex bot and CodeRabbit included, treat these as P1:

- A committed secret, kubeconfig, Terraform state or `.tfvars` with real values, or a known-public example password as a default.
- A chart change that lets a path reach the api around the frontend edge, a container outside Pod Security `restricted`, or a migrate hook that references a chart-created resource.
- A recipe change to what an apply creates, or a moved `geolens_version` default, without a real-account run recorded in the README and PR.
- A chart upgrade note missing from a recipe README or cloud guide without a `chart_only` reason.
- A loosened guard or CI job, or a renamed required check without the branch protection change.

## Security

- Never commit secrets, kubeconfigs, `.tfvars` with real values, or Terraform state. Example files carry only `<placeholder>` values or obvious dummies (`example.com`, repeated-digit account IDs and GUIDs), never a name someone else could register, such as a bucket. `values-aws.yaml` points at an `existingSecret` instead of holding a DSN.
- Keep cloud account and subscription IDs out of committed files and PR text; this repository is public.
- Keep credentials off Helm command lines; use a pre-created Secret.
- The backend refuses to boot on known-public example passwords; never reintroduce one as a default.
- Report a chart or recipe vulnerability to security@getgeolens.com, not in a public issue.
