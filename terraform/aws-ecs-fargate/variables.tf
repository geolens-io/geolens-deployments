variable "name" {
  description = "Name prefix for every resource this module creates."
  type        = string
  default     = "geolens"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "geolens_version" {
  description = "GeoLens release tag for the api, worker and frontend images."
  type        = string
  default     = "1.18.1"
}

variable "titiler_version" {
  description = "Tag for ghcr.io/developmentseed/titiler."
  type        = string
  default     = "2.2.1"
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
  description = "Public URL of the deployment. Empty means http://<alb dns name>. Set this when you put a domain or CDN in front of the load balancer."
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "ACM certificate for HTTPS. When set, the load balancer serves 443 and redirects 80 to it."
  type        = string
  default     = ""
}

variable "admin_username" {
  description = "Username of the bootstrap admin account."
  type        = string
  default     = "admin"
}

variable "admin_password" {
  description = "Password for the bootstrap admin. Empty means generate one. The backend rejects passwords under 12 characters or using fewer than 3 character classes."
  type        = string
  default     = ""
  sensitive   = true
}

variable "skip_final_snapshot" {
  description = "Skip the RDS final snapshot on destroy."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Block terraform destroy from deleting the database."
  type        = bool
  default     = false
}

variable "s3_force_destroy" {
  description = "Let terraform destroy delete the bucket while it still holds objects."
  type        = bool
  default     = false
}

variable "upload_max_size_mb" {
  description = "Largest upload the api and the frontend edge accept, in MB. Rendered into both so they cannot drift apart."
  type        = number
  default     = 500
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
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

variable "worker_concurrency" {
  description = "Parallel job slots in the worker. Keep 1 per vCPU."
  type        = number
  default     = 1
}

# The two escape hatches that make every other GeoLens option reachable, the
# same way the Helm chart's extraEnv and existingSecret do. The configuration
# reference is https://docs.getgeolens.com/guides/quickstart/configuration/.
variable "extra_env" {
  description = "Extra plain environment for the api, worker and migrate containers, for example REGISTRATION_ENABLED, OPENAI_MODEL, SMTP_HOST or CORS_ALLOWED_ORIGINS. An entry here overrides a default of the same name."
  type        = map(string)
  default     = {}
}

variable "extra_secrets" {
  description = "Extra secrets for the api, worker and migrate containers: env name to an ECS valueFrom, that is a Secrets Manager ARN with an optional :json-key:: suffix. Use it for OPENAI_API_KEY, ANTHROPIC_API_KEY, SMTP_PASSWORD, OAuth client secrets and TILE_SIGNING_SECRET. The execution role is granted read on each secret."
  type        = map(string)
  default     = {}
}
