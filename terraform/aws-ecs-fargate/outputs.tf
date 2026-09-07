output "app_url" {
  description = "Public URL of the deployment."
  value       = local.public_app_url
}

output "load_balancer_dns_name" {
  description = "Hostname of the load balancer. Point your domain's alias record here when public_app_url is set."
  value       = aws_lb.this.dns_name
}

output "admin_username" {
  description = "Bootstrap admin username."
  value       = var.admin_username
}

output "admin_password_command" {
  description = "Reads the generated admin password out of Secrets Manager."
  value       = "aws secretsmanager get-secret-value --region ${var.region} --secret-id ${aws_secretsmanager_secret.app.arn} --query SecretString --output text | jq -r .GEOLENS_ADMIN_PASSWORD"
}

output "secret_arn" {
  description = "Secrets Manager secret holding the database DSN, JWT key and admin credentials."
  value       = aws_secretsmanager_secret.app.arn
}

output "s3_bucket" {
  description = "Bucket holding uploaded datasets and derived rasters."
  value       = aws_s3_bucket.this.id
}

output "cluster_name" {
  description = "ECS cluster name, for aws ecs and aws logs commands."
  value       = aws_ecs_cluster.this.name
}

output "database_endpoint" {
  description = "RDS endpoint. Only reachable from inside the VPC."
  value       = aws_db_instance.this.address
}
