terraform {
  required_version = ">= 1.9"

  required_providers {
    # Exact pins, moved by Dependabot. Given a range, its lock-file update
    # resolves the newest version the range allows and skips the 7-day cooldown
    # in dependabot.yml (#56, #62); a pin makes the lock follow the version it chose.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "5.6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  # 5.0 stopped registering resource providers on its own, and a subscription
  # that has never used one of these rejects the first resource under it.
  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.App",
    "Microsoft.Cache",
    "Microsoft.DBforPostgreSQL",
    "Microsoft.Network",
    "Microsoft.OperationalInsights",
    "Microsoft.Storage",
  ]

  features {
    # The storage account only accepts traffic from the Container Apps subnet,
    # so Terraform has to stay on the management plane to manage it.
    storage {
      data_plane_available = false
    }

    # Otherwise destroy only soft-deletes the workspace, which holds its name
    # for 14 days and makes the next apply of the same stack fail.
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
  }
}
