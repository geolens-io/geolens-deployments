# Repository Guidelines

Infrastructure for [GeoLens](https://github.com/geolens-io/geolens): a Helm
chart, Terraform recipes for AWS and Azure, and a provisioning guide per cloud.
No application code lives here. Shared agent instructions live in this file;
keep `CLAUDE.md` as only `@AGENTS.md`. Keep this file to actionable conventions
and traps, and link to the source for detail.

## Project map

- `helm/geolens/`: the chart. `values.yaml` documents every value with the reason for its default; `templates/` renders the api, worker, frontend and titiler workloads, the migrate hook, NetworkPolicies, PodDisruptionBudgets and the optional `/app/staging` claim.
- `terraform/aws-ecs-fargate/`, `terraform/azure-container-apps/`: one root-module recipe per cloud. Each README covers what it deploys, cost, teardown and a "Validated" record.
- `clouds/`: the manual counterpart of each recipe, one page per cloud. Change a recipe and its page together; provider-neutral material belongs on the docs site.
- `examples/`: values files to adapt.
- `.github/ci/`: CI-only fixtures. `postgres.yaml` is not a production manifest. `ingest-smoke.sh <url> <user> <password>` pushes a vector and a raster through any running install's edge and fetches a tile.
- `.github/workflows/`: `ci.yml`, `release-charts.yml`, `version-drift.yml`.

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

terraform fmt -check -recursive terraform
for dir in terraform/*/; do
  terraform -chdir="$dir" init -backend=false && terraform -chdir="$dir" validate
done
bash terraform/aws-ecs-fargate/test-pilot-profile.sh
bash terraform/azure-container-apps/test-validations.sh
```

- `helm lint` does not enforce `required`, so lint with the same values the template command uses.
- Each guard in `ci.yml`'s `lint-and-template` job is plain shell, named for the invariant it pins. Run the ones that cover what you change.
- A NOTES change needs the kind job: Helm 3 renders NOTES only in a dry run against a live cluster.
- Documentation-only edits need link and command checks and `git diff --check`, not the whole matrix.
- Report failed or unrun checks accurately.

## CI, branch protection and releases

- `main` requires five checks by name: `lint-and-template (helm 3)`, `lint-and-template (helm 4)`, `kind install test (helm 3)`, `kind install test (helm 4)` and `terraform validate`. Bumping a pinned Helm version keeps the names. Renaming a job or adding a Helm major changes them, so update the branch protection rule in the same change.
- `lint-and-template` renders three configurations and runs guards that each pin a bug rendering alone would not catch. Add a guard for anything a render can pass while a real cluster fails.
- `kind install test` installs at the chart's default tags into a namespace enforcing Pod Security `restricted`, with the NetworkPolicies on and a shared staging claim. It runs Calico because kindnet's policy engine breaks DNS for policy-selected pods. It ingests through the edge, checks that only the frontend answers pods outside the release, and re-runs the migrate hook with `helm upgrade --reuse-values`.
- `terraform validate` runs `fmt`, `init -backend=false` and `validate` in every recipe, then both test scripts. It never touches a cloud account.
- `release-charts.yml` runs after `chart-ci` passes on a push to `main`, from the commit it tested, and on `workflow_dispatch` from `main`. It attaches the packaged chart to a GitHub Release and the `gh-pages` index, and pushes the same package to GHCR signed with keyless cosign. Reruns and merges without a version bump never republish an existing version. The OCI step still signs the current version when an earlier run stopped before signing it, as long as its files match the tested commit, so the next green push or a rerun finishes a partial release. `workflow_dispatch` also publishes a version whose bump merged before the workflow existed.
- `version-drift.yml` runs Mondays at 06:17 UTC and fails when a pinned GeoLens version is behind the latest release.

## Versioning

- Bump `Chart.yaml` `version` for every chart change that should be released. Landing that bump on `main` is the release.
- `appVersion`, the three `ghcr.io/geolens-io/*` tags in `values.yaml` and the `geolens_version` default in each recipe's `variables.tf` move together.
- The `ghcr.io/developmentseed/titiler` tag is bumped deliberately, not on a schedule: upstream ships security fixes as ordinary bugfix releases with no advisory.
- Each recipe pins its Terraform providers to exact versions, and Dependabot moves the pins. Given a range, Dependabot's lock-file update resolves the newest version the range allows, which skips the 7-day cooldown in `dependabot.yml`.
- Pin every workflow action to a full commit SHA with its version in a trailing comment (`# v4.4.0`); Dependabot updates both. Helm versions in `setup-helm` inputs are pinned by hand.

## Chart conventions

- Document each new value in `values.yaml` with the reason for its default, not only its meaning.
- Every generated env entry is skipped when the operator already set that name in `extraEnv`: build an override-name set first and guard each static entry against it. Duplicate env names break strategic-merge tooling, which keys `env` by `name`, so an Argo or Helm upgrade can fail before a pod rolls.
- The migrate Job is a pre-install/pre-upgrade hook and must reference no chart-created resource: no `serviceAccountName`, no `secretRef` to the chart Secret, no ConfigMap `envFrom`. Values it needs are inlined. It carries `hook-delete-policy: before-hook-creation,hook-succeeded`, without which Job immutability fails every upgrade.
- `serviceAccount.create` defaults to false on purpose: flipping an existing install to a fresh account would silently drop the `default` account's imagePullSecrets, RBAC and annotations.
- Dereference every new top-level values map through `| default dict`. A `--reuse-values` upgrade from a release that predates the map supplies nothing, and a bare dereference aborts rendering. A new value whose default matters, such as a security context or a grace period, needs the same default in the template, or reused-value upgrades silently skip it.
- The Secret renders `data` with `b64enc`, never `stringData`, or removed keys survive `helm upgrade`.
- Every container stays within Pod Security `restricted` (`geolens.containerSecurityContext` plus a non-root user). The kind job enforces it, so a new container or hook fails CI rather than a hardened cluster.
- The ingress routes everything to the frontend edge. Never add a path that reaches the api directly; it would bypass the metrics block, the anonymous raster rate limit and log redaction.

## Recipe conventions

- One root module per cloud, with no registry modules. A `# ponytail:` comment marks each deliberate shortcut and names its ceiling.
- Set only what the recipe wires, and leave application defaults to the images: a hard-coded list goes stale when GeoLens adds to it.
- `extra_env` and `extra_secrets` reserve every name the recipe generates or wires, listed once as `reserved_env` in `variables.tf`. A newly wired setting joins that list.
- An input that passes `terraform plan` but fails partway through `apply` gets a variable validation and a case in the recipe's test script. Providers skip their own checks on nested sets while any value is unknown, which is always the case on a first apply.
- Validate a change on a real account from a scratch copy of the module, so no state or tfvars reach the repo. Check `/api/health`, run `ingest-smoke.sh` through the edge, destroy, and confirm nothing is left, including Azure's `<name>-rg-infra` and soft-deleted resources. Record the run in the recipe README's "Validated" section and in the PR.

## Comments

- Comments state the current reason or constraint. Remove ones that repeat the code.
- Keep provenance in Git history, issues and PRs. Do not tag comments with PR or issue numbers, review rounds or agent names; keep a reference only when it supplies context the comment cannot state. Older comments still carry such anchors: drop them when you touch those lines, and never add new ones.
- Template comments stay within three lines.

## Commits and pull requests

- Use scoped Conventional Commits with an imperative subject, such as `fix(chart): 0.4.39 warns that storage.backend=azure needs a shared staging volume`, and a DCO sign-off (`git commit -s`).
- Say what changed in the rendered output, and name the cluster or account a change was validated against.
- A PR description has Summary, Evidence (before and after, for a bug) and Merge Danger (door and blast radius) sections. PRs are squash-merged.

## Security

- Never commit secrets, kubeconfigs, `.tfvars` with real values, or Terraform state. Example files carry `<placeholder>` values only, and `values-aws.yaml` points at an `existingSecret` instead of holding a DSN.
- Keep credentials off Helm command lines; use a pre-created Secret.
- The backend refuses to boot on known-public example passwords; never reintroduce one as a default.
- Report a chart or recipe vulnerability to security@getgeolens.com, not in a public issue.
