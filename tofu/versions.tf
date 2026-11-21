terraform {
  # Native S3 state locking (use_lockfile) requires OpenTofu 1.10.2 or newer.
  required_version = ">= 1.10.2"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
    porkbun = {
      source  = "jianyuan/porkbun"
      version = "0.3.4"
    }
  }
}

provider "hcloud" {
  # Prefer HCLOUD_TOKEN in the environment. The variable is optional so the
  # token never has to be written to a .tfvars file.
  token = var.hcloud_token
}

provider "porkbun" {
  # PORKBUN_API_KEY and PORKBUN_SECRET_KEY come from the environment.
}
