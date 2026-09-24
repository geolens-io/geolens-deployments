locals {
  tags = {
    Project   = "geolens"
    ManagedBy = "terraform"
  }

  # Two /24s out of whatever vnet_cidr is.
  subnet_bits = 24 - tonumber(split("/", var.vnet_cidr)[1])
}

resource "azurerm_resource_group" "this" {
  name     = "${var.name}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name}-vnet"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

# A workload profiles environment needs its own subnet, delegated to it.
# /27 is the floor; a /24 leaves room to scale out. The storage service
# endpoint is what lets the storage account admit this subnet and nothing else.
resource "azurerm_subnet" "apps" {
  name                 = "apps"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, local.subnet_bits, 0)]

  service_endpoint {
    service = "Microsoft.Storage"
  }

  delegation {
    name = "container-apps"

    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Private access: the server gets an address in this subnet and no public
# endpoint. The choice is made at creation and cannot be changed afterwards.
resource "azurerm_subnet" "database" {
  name                 = "database"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, local.subnet_bits, 1)]

  # Flexible Server adds this endpoint to its subnet on creation; declaring it
  # keeps later plans from trying to take it away. The storage account still
  # admits only the apps subnet.
  service_endpoint {
    service = "Microsoft.Storage"
  }

  delegation {
    name = "postgres"

    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.name}.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                = "${var.name}-vnet"
  private_dns_zone_id = azurerm_private_dns_zone.postgres.id
  virtual_network_id  = azurerm_virtual_network.this.id
  tags                = local.tags

  depends_on = [azurerm_subnet.database]
}
