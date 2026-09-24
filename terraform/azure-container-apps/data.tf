locals {
  # Container Apps names an app <app>.<environment domain>, so the public
  # address is known before the app exists and can go into its own env.
  public_app_url = var.public_app_url != "" ? trimsuffix(var.public_app_url, "/") : "https://${var.name}-app.${azurerm_container_app_environment.this.default_domain}"

  # The backend reads DATABASE_URL_OVERRIDE verbatim, so anything that needs
  # percent-encoding in the password breaks the DSN. Generating without special
  # characters avoids the encoding step entirely.
  database_url = "postgresql+asyncpg://geolens:${random_password.db.result}@${azurerm_postgresql_flexible_server.this.fqdn}:5432/geolens"

  # Access keys are base64, and a / in one reads as the start of a URL path,
  # so the key is percent-encoded before it goes in as the password.
  redis_url = var.cache_enabled ? format(
    "rediss://:%s@%s:%d/0",
    urlencode(azurerm_managed_redis.this[0].default_database[0].primary_access_key),
    azurerm_managed_redis.this[0].hostname,
    azurerm_managed_redis.this[0].default_database[0].port,
  ) : ""

  # Every credential the containers get, env name to value. Each becomes a
  # Container Apps secret named after it (DATABASE_URL_OVERRIDE is
  # database-url-override) and reaches the containers by reference.
  # ponytail: Container Apps secrets and Terraform state, not Key Vault. Key
  # Vault references are the upgrade when rotation or auditing has to happen
  # outside Terraform.
  app_secrets = merge(
    {
      DATABASE_URL_OVERRIDE     = local.database_url
      JWT_SECRET_KEY            = random_password.jwt.result
      GEOLENS_ADMIN_USERNAME    = var.admin_username
      GEOLENS_ADMIN_PASSWORD    = var.admin_password != "" ? var.admin_password : random_password.admin.result
      SECRET_ENCRYPTION_KEY     = replace(replace(random_bytes.secret_encryption_key.base64, "+", "-"), "/", "_")
      AZURE_STORAGE_ACCOUNT_KEY = azurerm_storage_account.this.primary_access_key
    },
    var.cache_enabled ? { REDIS_URL = local.redis_url } : {},
    var.extra_secrets,
  )
}

# Storage accounts, database servers and caches share global namespaces.
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Flexible Server wants three of four character classes, so each is forced.
resource "random_password" "db" {
  length      = 32
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

resource "random_password" "jwt" {
  length  = 64
  special = false
}

# GeoLens holds passwords to three character classes, and a plain
# alphanumeric draw skips a class often enough to matter (about 1.5% of
# 24-character draws have no digit), so each class is forced.
resource "random_password" "admin" {
  length      = 24
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

# A dedicated key for stored SSO secrets, so a JWT rotation cannot strand
# them. The app keeps the JWT-derived key as its last fallback; replacing this
# key strands what it wrote.
resource "random_bytes" "secret_encryption_key" {
  length = 32
}

# ponytail: the administrator login is both the migration and application
# login, as on AWS. Split them when the database is shared.
resource "azurerm_postgresql_flexible_server" "this" {
  name                = "${var.name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  version             = "17"
  sku_name            = var.db_sku_name
  storage_mb          = var.db_storage_mb

  administrator_login    = "geolens"
  administrator_password = random_password.db.result

  delegated_subnet_id           = azurerm_subnet.database.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  backup_retention_days = var.backup_retention_days
  tags                  = local.tags

  # Azure picks the zone when none is given and reports it afterwards.
  lifecycle {
    ignore_changes = [zone]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

# Flexible Server refuses CREATE EXTENSION for anything missing from this
# list, whatever the role's privileges, and the error reads like a
# permissions problem. The bootstrap in migrate.py needs all four.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "POSTGIS,VECTOR,PG_TRGM,UNACCENT"
}

# A new server has only the postgres database.
resource "azurerm_postgresql_flexible_server_database" "geolens" {
  name      = "geolens"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# The app authenticates with the account key (it ships without azure-identity,
# so managed identity is not an option), and only the Container Apps subnet
# may reach the account at all: presigned uploads are S3-only, so no browser
# ever talks to Blob Storage directly.
resource "azurerm_storage_account" "this" {
  name                            = "${substr(replace(var.name, "-", ""), 0, 18)}${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = local.tags

  network_rules {
    default_action             = "Deny"
    virtual_network_subnet_ids = [azurerm_subnet.apps.id]
    # Left out, bypass keeps Azure's AzureServices default, which also lets the
    # trusted Microsoft services past this rule (codex review on #59).
    bypass = ["None"]
  }
}

resource "azurerm_storage_container" "uploads" {
  name                  = "geolens-uploads"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Only STORAGE_PROVIDER=s3 hands an upload to the worker through the bucket.
# With azure the api writes it to /app/staging and the worker reads the same
# path, so the two apps share this file share there, as the Helm chart's
# staging claim does. Billed by the GiB used; the quota is only a ceiling.
# ponytail: SMB on a standard account, so raster conversions write over the
# network. A premium NFS share is the upgrade when ingest throughput matters.
resource "azurerm_storage_share" "staging" {
  name               = "staging"
  storage_account_id = azurerm_storage_account.this.id
  quota              = 100
}

# ponytail: one node on a public endpoint with TLS and key authentication, as
# the cache page describes. Turn on high availability and add a private
# endpoint when the cache holds anything worth more than a rebuild.
resource "azurerm_managed_redis" "this" {
  count = var.cache_enabled ? 1 : 0

  name                      = "${var.name}-${random_string.suffix.result}"
  resource_group_name       = azurerm_resource_group.this.name
  location                  = azurerm_resource_group.this.location
  sku_name                  = "Balanced_B0"
  high_availability_enabled = false
  tags                      = local.tags

  default_database {
    access_keys_authentication_enabled = true
    client_protocol                    = "Encrypted"
  }
}
