variable "subscription_id" {
  description = "Azure subscription to deploy into, for example from `az account show --query id -o tsv`. The azurerm provider no longer falls back to the CLI's default subscription."
  type        = string
}

variable "name" {
  description = "Name prefix for every resource this module creates. The resource group, apps and job use it as is; the storage account, database server and cache also add a random suffix, since their names are global."
  type        = string
  default     = "geolens"

  # Container App names stop at 32 characters, which leaves room for the
  # longest suffix here, -migrate, and cannot contain "--". The storage account
  # keeps the first 18 characters, hyphens dropped.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.name)) && !strcontains(var.name, "--")
    error_message = "name must be 3 to 20 lowercase letters, digits or single hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "location" {
  description = "Azure region. Many subscriptions cannot create a PostgreSQL Flexible Server in the busiest regions (eastus, eastus2 and westus2 among them), and Container Apps turns environments away in regions short of capacity; see the README before picking another."
  type        = string
  default     = "westus3"
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

variable "vnet_cidr" {
  description = "Address space for the virtual network this module creates. Its first /24 holds the Container Apps environment and its second /24 the database. It cannot hold a range Azure reserves, and its first /24 must avoid the ranges Container Apps reserves."
  type        = string
  default     = "10.30.0.0/16"

  # cidrsubnet takes IPv6, a /0 and host bits as well, and cidrnetmask refuses
  # only IPv6; Azure refuses all of them, and anything larger than /2, once
  # provisioning has begun.
  validation {
    condition     = can(cidrnetmask(var.vnet_cidr)) && can(cidrsubnet(var.vnet_cidr, 24 - tonumber(split("/", var.vnet_cidr)[1]), 1)) && try(tonumber(split("/", var.vnet_cidr)[1]) >= 2 && cidrhost(var.vnet_cidr, 0) == split("/", var.vnet_cidr)[0], false)
    error_message = "vnet_cidr must be an IPv4 CIDR from /2 to /23 that starts at its network address (10.30.0.0/16, not 10.30.1.0/16): Azure takes nothing else, and two /24 subnets must fit in it."
  }

  # Azure refuses these in any network, and Container Apps refuses a subnet
  # overlapping its own reserved ranges, only once the network and database
  # exist. Two IPv4 networks overlap exactly when both, masked to the shorter
  # prefix, give the same address.
  validation {
    condition = try(alltrue([
      for r in ["127.0.0.0/8", "168.63.129.16/32", "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32"] :
      cidrhost("${cidrhost(var.vnet_cidr, 0)}/${min(tonumber(split("/", var.vnet_cidr)[1]), tonumber(split("/", r)[1]))}", 0) !=
      cidrhost("${split("/", r)[0]}/${min(tonumber(split("/", var.vnet_cidr)[1]), tonumber(split("/", r)[1]))}", 0)
    ]), true)
    error_message = "vnet_cidr must not overlap 127.0.0.0/8, 168.63.129.16/32, 169.254.0.0/16, 224.0.0.0/4 or 255.255.255.255/32, which Azure reserves in every virtual network."
  }

  # Every range here is /24 or larger, so the apps subnet overlaps one only by
  # sitting inside it.
  validation {
    condition = try(alltrue([
      for r in ["100.100.0.0/17", "100.100.128.0/19", "100.100.160.0/19", "100.100.192.0/19", "172.30.0.0/16", "172.31.0.0/16", "192.0.2.0/24"] :
      cidrhost("${cidrhost(cidrsubnet(var.vnet_cidr, 24 - tonumber(split("/", var.vnet_cidr)[1]), 0), 0)}/${split("/", r)[1]}", 0) != split("/", r)[0]
    ]), true)
    error_message = "The first /24 of vnet_cidr is the Container Apps subnet and must not overlap 100.100.0.0/17, 100.100.128.0/19, 100.100.160.0/19, 100.100.192.0/19, 172.30.0.0/16, 172.31.0.0/16 or 192.0.2.0/24, which Container Apps reserves."
  }
}

variable "app_replicas" {
  description = "Replicas of the app (frontend, api and titiler together). More than one needs cache_enabled, since each api otherwise caches in its own memory."
  type        = number
  default     = 1

  validation {
    condition     = var.app_replicas >= 1 && floor(var.app_replicas) == var.app_replicas
    error_message = "app_replicas must be a positive whole number."
  }

  validation {
    condition     = var.app_replicas == 1 || var.cache_enabled
    error_message = "app_replicas above 1 needs cache_enabled = true; without a shared cache every api replica keeps its own."
  }
}

variable "cache_enabled" {
  description = "Create an Azure Managed Redis instance and point the app at it. Only worth it for more than one api replica: with no REDIS_URL the api caches in process memory, which is correct for one."
  type        = bool
  default     = false
}

variable "public_app_url" {
  description = "Public origin once a custom domain is bound to the app, for example https://geolens.example.com. Empty means the app's own https://<app>.<environment domain> address. It feeds every URL the api hands out, so set it only after the domain resolves to the app."
  type        = string
  default     = ""

  # Label by label: 1 to 63 letters, digits or inner hyphens, at least two of
  # them, so geo..example.com cannot pass, and 253 characters in all, the DNS
  # limit.
  validation {
    condition     = var.public_app_url == "" || (can(regex("^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$", trimsuffix(var.public_app_url, "/"))) && length(trimprefix(trimsuffix(var.public_app_url, "/"), "https://")) <= 253)
    error_message = "public_app_url must be empty or an https:// origin whose hostname has valid DNS labels and at most 253 characters, with no port or path."
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

variable "backup_retention_days" {
  description = "PostgreSQL point-in-time restore window, 7 to 35 days."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 7 and 35."
  }
}

variable "upload_max_size_mb" {
  description = "Largest upload the api and the frontend edge accept, in MB. Rendered into both so they cannot drift apart. On Azure every upload streams through the api, since presigned uploads are S3-only."
  type        = number
  default     = 500

  validation {
    condition     = var.upload_max_size_mb >= 1 && floor(var.upload_max_size_mb) == var.upload_max_size_mb
    error_message = "upload_max_size_mb must be a positive whole number."
  }
}

variable "db_sku_name" {
  description = "PostgreSQL Flexible Server SKU."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "db_storage_mb" {
  description = "PostgreSQL storage in MB. Azure accepts only its fixed sizes (32768, 65536, 131072 and up) and can grow a disk but never shrink one."
  type        = number
  default     = 32768
}

variable "api_cpu" {
  description = "vCPU for the api container, in steps of 0.25; it gets twice that in GiB of memory. The frontend (0.25) and titiler (0.5) share the app with it, and the three must stay within 4 vCPU."
  type        = number
  default     = 1

  validation {
    condition     = var.api_cpu >= 0.25 && var.api_cpu <= 3.25 && floor(var.api_cpu * 4) == var.api_cpu * 4
    error_message = "api_cpu must be a multiple of 0.25 between 0.25 and 3.25."
  }
}

variable "worker_cpu" {
  description = "vCPU for the worker, in steps of 0.25 up to 4; it gets twice that in GiB of memory. GDAL ingestion is memory hungry, so raise this before large rasters."
  type        = number
  default     = 1

  validation {
    condition     = var.worker_cpu >= 0.25 && var.worker_cpu <= 4 && floor(var.worker_cpu * 4) == var.worker_cpu * 4
    error_message = "worker_cpu must be a multiple of 0.25 between 0.25 and 4."
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
  # api-only metrics directory (the worker and migrate job crash on it), the
  # shutdown window the worker's grace period is sized for, values the frontend
  # edge shares, which come from their variables, the storage and port titiler
  # is wired to, and the database TLS mode and role settings, which the app
  # holds to the one login the migrate job's provisioner borrow is written for.
  reserved_env = [
    "AZURE_STORAGE_ACCOUNT_KEY", "DATABASE_URL_OVERRIDE", "GEOLENS_ADMIN_PASSWORD", "GEOLENS_ADMIN_USERNAME", "JWT_SECRET_KEY", "REDIS_URL", "SECRET_ENCRYPTION_KEY",
    "GEOLENS_API_RUN_MIGRATIONS", "GEOLENS_BOOTSTRAP_B64", "SECRETS_REVISION", "UPLOAD_STAGING_DIR",
    "PROMETHEUS_MULTIPROC_DIR", "PUBLIC_API_URL", "PUBLIC_APP_URL", "UPLOAD_MAX_SIZE_MB", "WORKER_SHUTDOWN_TIMEOUT",
    "AZURE_STORAGE_ACCOUNT_URL", "AZURE_STORAGE_CONNECTION_STRING", "STORAGE_PROVIDER", "TITILER_BASE_URL",
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
  description = "Extra secret environment for the api, worker and migrate containers, env name to value, for example OPENAI_API_KEY, SMTP_PASSWORD, OAuth client secrets and TILE_SIGNING_SECRET. Stored as Container Apps secrets, so the values also sit in Terraform state. An entry here replaces a plain default of the same name."
  type        = map(string)
  default     = {}
  sensitive   = true

  validation {
    condition     = length(setintersection(toset(keys(var.extra_secrets)), toset(local.reserved_env))) == 0
    error_message = "extra_secrets cannot redefine any of ${join(", ", local.reserved_env)}. The recipe owns them; public_app_url, upload_max_size_mb and the admin variables set the ones meant to change."
  }

  validation {
    condition     = length(setintersection(toset(keys(var.extra_secrets)), toset(keys(var.extra_env)))) == 0
    error_message = "A name cannot be in both extra_env and extra_secrets."
  }

  # Container Apps secret names are the env names lowercased with - for _, and
  # must end in a letter or digit. The provider skips that check at plan time
  # while any secret value is unknown, so the apply fails.
  validation {
    condition     = alltrue([for k in keys(var.extra_secrets) : can(regex("^[A-Z]([A-Z0-9_]*[A-Z0-9])?$", k))])
    error_message = "extra_secrets keys must be environment variable names of uppercase letters, digits and underscores, starting with a letter and ending with a letter or digit."
  }
}
