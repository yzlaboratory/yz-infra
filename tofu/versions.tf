terraform {
  # Native S3 state locking (use_lockfile) requires OpenTofu 1.10.2 or newer.
  required_version = ">= 1.10.2"

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
