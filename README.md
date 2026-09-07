# GeoLens Deployments

Kubernetes and cloud deployment packaging for
[GeoLens](https://github.com/geolens-io/geolens).

[![chart-ci](https://github.com/geolens-io/geolens-deployments/actions/workflows/ci.yml/badge.svg)](https://github.com/geolens-io/geolens-deployments/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

GeoLens installs on a single host with Docker Compose, and that is the path the
[quickstart](https://docs.getgeolens.com/guides/quickstart/install/) documents.
This repo covers the deployments that need more than one host: a Helm chart for
Kubernetes, and a Terraform recipe for AWS ECS Fargate. Both run the same
Apache-2.0 GeoLens images the compose stack runs.

Everything here is community maintained and support is best effort. CI installs
every change into a throwaway [kind](https://kind.sigs.k8s.io/) cluster, sends a
smoke request through the frontend edge, then upgrades the release. The
Terraform recipe was applied to a real AWS account and torn down again. Nobody
keeps a long-lived production cluster running from this repo, so that CI run is
what backs the chart. Issues and pull requests are welcome.

## What's here

| Path | What it is |
| --- | --- |
| [`helm/geolens`](helm/geolens/) | Helm chart for Kubernetes: API, worker, frontend edge, Titiler, and an Alembic migration hook Job. Values, required secrets, storage, database, and upgrade notes are in the [chart README](helm/geolens/README.md). |
| [`examples/`](examples/) | Values files to adapt. [`values-aws.yaml`](examples/values-aws.yaml) is an EKS install with S3 and RDS PostgreSQL, validated on a real cluster. |
| [`terraform/aws-ecs-fargate`](terraform/aws-ecs-fargate/) | Terraform recipe: ECS Fargate, RDS PostgreSQL, S3, ElastiCache Valkey, and an ALB. Validated against a real AWS account, then torn down. See its own README. Azure, Google Cloud and DigitalOcean recipes are planned; [`terraform/README.md`](terraform/README.md) has the notes. |

If you want compose on a single host backed by a managed database, bucket, and
cache, that is documented on the docs site instead: the
[cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/)
covers AWS, Google Cloud, and DigitalOcean.

## Install

The chart is published to a hosted Helm repository:

```bash
helm repo add geolens https://geolens-io.github.io/geolens-deployments
helm upgrade --install geolens geolens/geolens [--set ...]
```

The same package is also published as OCI:

```bash
helm upgrade --install geolens oci://ghcr.io/geolens-io/charts/geolens [--set ...]
```

Or install from a checkout of this repo by replacing `geolens/geolens` with the
path `helm/geolens`.

The backend refuses to boot without admin credentials, a JWT secret, and a
database URL, so none of those commands work bare. The
[chart README](helm/geolens/README.md) has the required values, the
`existingSecret` key table, and the rest of the reference.

## Versioning and releases

`appVersion`, the three `ghcr.io/geolens-io/*` image tags in `values.yaml`,
and the Terraform recipe's `geolens_version` default track GeoLens releases and
move together. The `version-drift` workflow runs weekly and fails when any of
them has fallen behind the latest GeoLens release.

Chart releases are cut by landing a `Chart.yaml` `version` bump on `main`. Any
push to `main` touching `helm/**` runs `release-charts`, which packages the
chart, attaches it to a GitHub Release, updates the `gh-pages` index, and pushes
the same package to GHCR. Both legs skip a version that is already published, so
a rerun or a non-bump edit under `helm/` publishes nothing.

## Support

| Need | Where |
| --- | --- |
| Chart or Terraform bugs and questions | [Issues in this repo](https://github.com/geolens-io/geolens-deployments/issues) |
| GeoLens itself: usage, setup, ideas | [GitHub Discussions](https://github.com/geolens-io/geolens/discussions), and [SUPPORT.md](https://github.com/geolens-io/geolens/blob/main/SUPPORT.md) for how requests are routed |
| Security vulnerabilities | Email security@getgeolens.com rather than opening a public issue. The core [security policy](https://github.com/geolens-io/geolens/blob/main/.github/SECURITY.md) describes the process and scopes deployment packaging to this repo |

Product documentation lives at [docs.getgeolens.com](https://docs.getgeolens.com).

## Scope

These artifacts deploy the Apache-2.0 GeoLens that
[`geolens-io/geolens`](https://github.com/geolens-io/geolens) ships, and nothing
else. Enterprise add-ons are separate work: they ship in a separately licensed
image, and their deployment artifacts are maintained privately, so they are out
of scope here. The open-core boundary is documented in
[EDITIONS.md](https://github.com/geolens-io/geolens/blob/main/EDITIONS.md).

The chart also does not install PostgreSQL, object storage, or the cache. Those
stay operator-owned services.

## License

Apache-2.0, the same license as GeoLens. See [LICENSE](LICENSE).

The GeoLens name, logo, and brand assets are not covered by that license. See
[TRADEMARKS.md](https://github.com/geolens-io/geolens/blob/main/TRADEMARKS.md).
