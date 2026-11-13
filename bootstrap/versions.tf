terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "azurerm" {
  subscription_id     = var.subscription_id
  storage_use_azuread = true
  features {
    key_vault {
      # On destroy, leave the vault soft-deleted (recoverable for 7 days) instead of purging it.
      purge_soft_delete_on_destroy = false
    }
  }
}
