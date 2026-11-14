terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }
}

provider "hcloud" {
  # Prefer HCLOUD_TOKEN in the environment. The variable is optional so the
  # token never has to be written to a .tfvars file.
  token = var.hcloud_token
}
