terraform {
  required_version = ">= 1.9"

  required_providers {
    # Exact pins, moved by Dependabot. Given a range, its lock-file update
    # resolves the newest version the range allows and skips the 7-day cooldown
    # in dependabot.yml; a pin makes the lock follow the version it chose.
    aws = {
      source  = "hashicorp/aws"
      version = "6.63.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = merge(
      {
        Project   = "geolens"
        ManagedBy = "terraform"
      },
      var.pilot_profile ? { Deployment = var.name } : {}
    )
  }
}
