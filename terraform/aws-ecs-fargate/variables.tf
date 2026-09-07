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
