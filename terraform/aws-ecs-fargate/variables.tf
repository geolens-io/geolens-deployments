variable "name" {
  description = "Name prefix for every resource this module creates."
  type        = string
  default     = "geolens"
}

variable "pilot_profile" {
  description = "Require the safeguards used by the single-organization hosted pilot profile. Each organization still needs a separate module state and stack."
  type        = bool
  default     = false

  validation {
    condition = !var.pilot_profile || (
      can(regex("^geolens-[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.name)) &&
      var.deletion_protection &&
      !var.skip_final_snapshot &&
      var.backup_retention_days >= 7 &&
      var.s3_versioning_enabled &&
      var.s3_noncurrent_version_expiration_days >= 30 &&
      !var.s3_force_destroy &&
      var.app_desired_count == 1 &&
      var.worker_concurrency == 1
    )
    error_message = "pilot_profile requires a geolens-<org-slug> name, deletion protection, a final snapshot, at least 7 backup days, versioned S3 with at least 30-day noncurrent retention, and one app task and worker slot."
  }
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "geolens_version" {
  description = "GeoLens release tag for the api, worker and frontend images."
  type        = string
  default     = "1.20.0"
}

variable "titiler_version" {
  description = "Tag for ghcr.io/developmentseed/titiler."
  type        = string
  default     = "2.2.1"
}

variable "cpu_architecture" {
  description = "Fargate CPU architecture for every task. ARM64 (Graviton) costs about 20% less per vCPU-hour, and every image the recipe runs is published for both. Use X86_64 in a region without Graviton Fargate."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the VPC this module creates."
  type        = string
  default     = "10.20.0.0/16"
}

variable "app_desired_count" {
  description = "Number of app tasks (frontend + api + titiler)."
  type        = number
  default     = 1
}

variable "cache_enabled" {
  description = "Create an ElastiCache Valkey node and point the app at it."
  type        = bool
  default     = true
}

variable "public_app_url" {
  description = "Public URL of the deployment. Empty means http://<alb dns name>. Set this when you put a domain or CDN in front of the load balancer; with a certificate it must be the https:// origin, since it drives the S3 CORS rule and every URL the api hands out. The pilot profile requires a hostname without a path."
  type        = string
  default     = ""

  validation {
    condition = (var.acm_certificate_arn == "" || startswith(var.public_app_url, "https://")) && (
      !var.pilot_profile || (
        var.acm_certificate_arn != "" &&
        startswith(var.public_app_url, "https://") &&
        can(regex("^https://[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$", trimsuffix(var.public_app_url, "/"))) &&
        strcontains(var.public_app_url, ".")
      )
    )
    error_message = "With acm_certificate_arn set, public_app_url must be HTTPS; pilot_profile also requires a public hostname without a path and a certificate ARN."
  }
}

variable "acm_certificate_arn" {
  description = "ACM certificate for HTTPS. When set, the load balancer serves 443 and redirects 80 to it."
  type        = string
  default     = ""

  validation {
    condition     = !var.pilot_profile || can(regex("^arn:[a-z0-9-]+:acm:${var.region}:[0-9]{12}:certificate/[A-Za-z0-9-]+$", var.acm_certificate_arn))
    error_message = "pilot_profile requires an ACM certificate ARN in the configured AWS region. Confirm in ACM that it is ISSUED and covers public_app_url."
  }
}

variable "admin_username" {
  description = "Username of the bootstrap admin account."
  type        = string
  default     = "admin"

  # GeoLens refuses to boot on a blank one, after everything is provisioned.
  validation {
    condition     = trimspace(var.admin_username) != ""
    error_message = "admin_username must not be blank; GeoLens refuses to boot without one."
  }
}

variable "admin_password" {
  description = "Password for the bootstrap admin. Empty means generate one. A supplied one must meet the policy GeoLens holds every other password to: at least 12 characters, at most 72 bytes, and three of lowercase, uppercase, digit and symbol."
  type        = string
  default     = ""
  sensitive   = true

  # GeoLens seeds the admin without this check and fails to boot only on a
  # blank value, one over 72 bytes (bcrypt) or a known-public literal, all of
  # which the policy also rules out.
  validation {
    condition = var.admin_password == "" || (
      length(var.admin_password) >= 12 &&
      length(base64encode(var.admin_password)) <= 96 &&
      length([for re in ["\\p{Ll}", "\\p{Lu}", "\\p{Nd}", "[^\\p{L}\\p{Nd}]"] : re if can(regex(re, var.admin_password))]) >= 3
    )
    error_message = "admin_password must be empty, to generate one, or at least 12 characters and at most 72 bytes, with three of lowercase, uppercase, digit and symbol."
  }
}

variable "skip_final_snapshot" {
  description = "Skip the RDS final snapshot on destroy."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Block terraform destroy from deleting the database. Required by pilot_profile."
  type        = bool
  default     = false
}

variable "s3_force_destroy" {
  description = "Let terraform destroy delete the bucket while it still holds objects. Keep false for pilot data."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "RDS automated backup retention in days (0 disables automated backups; pilot_profile requires at least 7)."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 0 && var.backup_retention_days <= 35 && floor(var.backup_retention_days) == var.backup_retention_days
    error_message = "backup_retention_days must be a whole number from 0 through 35."
  }
}

# ponytail: off by default, so an overwrite or delete in the bucket is final.
# pilot_profile turns it on with noncurrent-version expiry.
variable "s3_versioning_enabled" {
  description = "Enable S3 object versioning and the configured noncurrent-version lifecycle. Required by pilot_profile."
  type        = bool
  default     = false
}

variable "s3_noncurrent_version_expiration_days" {
  description = "Days an S3 object version must be noncurrent before lifecycle expiration is requested. Used only when s3_versioning_enabled is true."
  type        = number
  default     = 30

  validation {
    condition     = var.s3_noncurrent_version_expiration_days >= 1 && floor(var.s3_noncurrent_version_expiration_days) == var.s3_noncurrent_version_expiration_days
    error_message = "s3_noncurrent_version_expiration_days must be a positive whole number."
  }
}

variable "upload_max_size_mb" {
  description = "Largest upload the api and the frontend edge accept, in MB. Rendered into both so they cannot drift apart."
  type        = number
  default     = 500

  validation {
    condition     = var.upload_max_size_mb >= 1 && floor(var.upload_max_size_mb) == var.upload_max_size_mb
    error_message = "upload_max_size_mb must be a positive whole number."
  }
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage_gb" {
  description = "Fixed encrypted RDS gp3 storage in GiB. No storage autoscaling is configured."
  type        = number
  default     = 20

  validation {
    condition     = var.db_allocated_storage_gb >= 20 && floor(var.db_allocated_storage_gb) == var.db_allocated_storage_gb
    error_message = "db_allocated_storage_gb must be a whole number of at least 20 GiB."
  }
}

variable "app_task" {
  description = "Fargate CPU units and memory (MiB) for the app task: frontend, api and titiler together."
  type        = object({ cpu = number, memory = number })
  default     = { cpu = 1024, memory = 3072 }
}

variable "worker_task" {
  description = "Fargate CPU units and memory (MiB) for the worker task. GDAL ingestion is memory hungry."
  type        = object({ cpu = number, memory = number })
  default     = { cpu = 1024, memory = 4096 }
}

variable "worker_ephemeral_storage_gb" {
  description = "Ephemeral disk for the worker task, 20 to 200 GiB. 20 is the Fargate default and is not sent explicitly; anything above it is. The worker pulls a raster down to /app/staging to convert it, so a large GeoTIFF plus its COG must fit here."
  type        = number
  default     = 20

  validation {
    condition     = var.worker_ephemeral_storage_gb >= 20 && var.worker_ephemeral_storage_gb <= 200
    error_message = "worker_ephemeral_storage_gb must be between 20 and 200."
  }
}

variable "worker_concurrency" {
  description = "Parallel job slots in the worker. Keep 1 per vCPU."
  type        = number
  default     = 1

  validation {
    condition     = var.worker_concurrency >= 1 && floor(var.worker_concurrency) == var.worker_concurrency
    error_message = "worker_concurrency must be a positive whole number."
  }
}

# The two escape hatches that make every other GeoLens option reachable, the
# same way the Helm chart's extraEnv and existingSecret do. The configuration
# reference is https://docs.getgeolens.com/guides/quickstart/configuration/.
locals {
  # Neither may set these: the generated secrets, the recipe's own wiring, the
  # api-only metrics directory (the worker and migrate task crash on it), the
  # shutdown window the worker's stopTimeout is sized for, values the frontend
  # edge shares, which come from their variables, the bucket, region and
  # credentials the app and GDAL are wired to (GDAL keeps an operator's
  # AWS_DEFAULT_REGION over S3_REGION, and a static key would win over the task
  # role), and the database TLS mode and role settings, which the app holds to
  # the one login.
  reserved_env = [
    "DATABASE_URL_OVERRIDE", "GEOLENS_ADMIN_PASSWORD", "GEOLENS_ADMIN_USERNAME", "JWT_SECRET_KEY", "SECRET_ENCRYPTION_KEY",
    "EXTRA_SECRETS_REVISION", "GEOLENS_API_RUN_MIGRATIONS", "GEOLENS_BOOTSTRAP_B64",
    "PROMETHEUS_MULTIPROC_DIR", "PUBLIC_API_URL", "PUBLIC_APP_URL", "UPLOAD_MAX_SIZE_MB", "WORKER_SHUTDOWN_TIMEOUT",
    "AWS_ACCESS_KEY_ID", "AWS_DEFAULT_REGION", "AWS_SECRET_ACCESS_KEY", "S3_ACCESS_KEY_ID", "S3_BUCKET", "S3_ENDPOINT", "S3_REGION", "S3_SECRET_ACCESS_KEY", "STORAGE_PROVIDER", "TITILER_BASE_URL",
    "DATABASE_SSL_MODE", "GEOLENS_MIGRATION_DB_ROLE", "GEOLENS_RUNTIME_DB_ROLE",
  ]
}

variable "extra_env" {
  description = "Extra plain environment for the api, worker and migrate containers, for example REGISTRATION_ENABLED, OPENAI_MODEL, SMTP_HOST or CORS_ALLOWED_ORIGINS. An entry here overrides a default of the same name."
  type        = map(string)
  default     = {}

  validation {
    condition     = length(setintersection(toset(keys(var.extra_env)), toset(local.reserved_env))) == 0
    error_message = "extra_env cannot set any of ${join(", ", local.reserved_env)}. The recipe owns them; public_app_url, upload_max_size_mb and the admin variables set the ones meant to change."
  }
}

variable "extra_secrets" {
  description = "Extra secrets for the api, worker and migrate containers: env name to an ECS valueFrom, that is a Secrets Manager ARN with an optional :json-key:: suffix. Use it for OPENAI_API_KEY, ANTHROPIC_API_KEY, SMTP_PASSWORD, OAuth client secrets and TILE_SIGNING_SECRET. The execution role is granted read on each secret. An entry here replaces a plain default of the same name."
  type        = map(string)
  default     = {}

  validation {
    condition     = length(setintersection(toset(keys(var.extra_secrets)), toset(local.reserved_env))) == 0
    error_message = "extra_secrets cannot redefine any of ${join(", ", local.reserved_env)}. The recipe owns them; public_app_url, upload_max_size_mb and the admin variables set the ones meant to change."
  }

  validation {
    condition     = length(setintersection(toset(keys(var.extra_secrets)), toset(keys(var.extra_env)))) == 0
    error_message = "A name cannot be in both extra_env and extra_secrets."
  }

  validation {
    condition = !var.pilot_profile || alltrue([
      for value in values(var.extra_secrets) : can(regex("^arn:[^:]+:secretsmanager:${var.region}:[0-9]{12}:secret:${var.name}/", value))
    ])
    error_message = "In pilot_profile, each extra secret must be an ARN in this region under the stack-specific Secrets Manager path <name>/."
  }
}

variable "extra_secrets_revision" {
  description = "Bump after rotating a secret named in extra_secrets. ECS reads secrets only at task start, and Terraform does not track their versions (the one data source that could would copy the values into state), so this value is rendered into the task definitions and changing it rolls the api, worker and migrate task onto the new values."
  type        = string
  default     = "1"
}
