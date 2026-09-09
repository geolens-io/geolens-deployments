# Cloud guidance

Provisioning notes for the managed services GeoLens runs on, one page per
cloud, kept next to the Terraform recipes that automate the same services.

| Cloud | Managed services | Recipe |
| --- | --- | --- |
| [AWS](aws.md) | RDS for PostgreSQL, S3, ElastiCache | [`terraform/aws-ecs-fargate`](../terraform/aws-ecs-fargate/) |
| [Azure](azure.md) | PostgreSQL Flexible Server, Blob Storage, Azure Cache for Redis | Planned: [#41](https://github.com/geolens-io/geolens-deployments/issues/41) |
| [Google Cloud](google-cloud.md) | Cloud SQL, Cloud Storage, Memorystore | Planned: [#42](https://github.com/geolens-io/geolens-deployments/issues/42) |
| [DigitalOcean](digitalocean.md) | Managed PostgreSQL, Spaces, Managed Valkey | Planned: [#43](https://github.com/geolens-io/geolens-deployments/issues/43) |

Each page covers only what its cloud does differently. The parts that are the
same everywhere live in two other places:

- [`terraform/README.md`](../terraform/README.md) states the five pieces any
  deployment has to provide, whether a recipe or a person provisions them.
- The docs site's
  [cloud deployment guide](https://docs.getgeolens.com/guides/quickstart/cloud-deployment/)
  holds the environment contract, the database bootstrap SQL, when migrations
  run, the health and metrics endpoints, and the troubleshooting that is not
  specific to one cloud.

Read the guide first, pick a cloud, then come back here.

## Reading a page

Every page follows the same order: database, object storage, cache, then how
the containers reach each other on that cloud's runtime, then the environment
variables that differ from the neutral set. The last section is the one to
diff against the guide; everything else in `.env` stays as the guide has it.

## Which path

A cloud page describes provisioning by hand, through the console or the CLI.
Two other paths exist and are usually less work:

- The [Helm chart](../helm/geolens/) if you already run Kubernetes. The
  managed database, bucket and cache still have to exist, so the database and
  storage sections here still apply.
- A [Terraform recipe](../terraform/) where one exists for your cloud. The
  recipe provisions the same services the page describes, so read the page for
  what the recipe is doing and skip the console steps.

## Status

AWS is the only cloud with a recipe applied against a real account. The other
three pages are written from the application's configuration contract and each
provider's own documentation, not from a validated deployment. Corrections
through issues and pull requests are welcome.
