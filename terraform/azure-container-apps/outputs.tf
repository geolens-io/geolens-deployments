output "app_url" {
  description = "Public URL of the deployment."
  value       = local.public_app_url
}

output "app_hostname" {
  description = "The app's own hostname. A custom domain's CNAME points here."
  value       = azurerm_container_app.app.ingress[0].fqdn
}

output "custom_domain_verification_id" {
  description = "Value for the asuid.<your domain> TXT record Azure checks before it binds a custom domain."
  # The provider marks it sensitive, but it exists to be published in DNS.
  value = nonsensitive(azurerm_container_app.app.custom_domain_verification_id)
}

output "admin_username" {
  description = "Bootstrap admin username."
  value       = var.admin_username
}

output "admin_password_command" {
  description = "Reads the admin password out of the app's secrets."
  value       = "az containerapp secret show --subscription ${var.subscription_id} --resource-group ${azurerm_resource_group.this.name} --name ${azurerm_container_app.app.name} --secret-name ${local.secret_names["GEOLENS_ADMIN_PASSWORD"]} --query value --output tsv"
}

output "logs_command" {
  description = "Streams the api's logs. Swap --container for frontend or titiler, or --name for the worker app."
  value       = "az containerapp logs show --subscription ${var.subscription_id} --resource-group ${azurerm_resource_group.this.name} --name ${azurerm_container_app.app.name} --container api --follow"
}

output "resource_group" {
  description = "Resource group holding everything this module creates."
  value       = azurerm_resource_group.this.name
}

output "storage_account" {
  description = "Storage account holding uploaded datasets and derived rasters. It only admits the Container Apps subnet."
  value       = azurerm_storage_account.this.name
}

output "database_fqdn" {
  description = "PostgreSQL server name. It resolves only inside the virtual network."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}
