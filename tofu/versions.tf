terraform {
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
  token = var.hcloud_token
}

provider "porkbun" {}
