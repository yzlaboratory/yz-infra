variable "hcloud_token" {
  description = "Hetzner Cloud API token. Prefer exporting HCLOUD_TOKEN instead."
  type        = string
  sensitive   = true
  default     = null
}

variable "name" {
  description = "Server and firewall name."
  type        = string
  default     = "yz-vps"
}

variable "server_type" {
  description = "Hetzner server type. cx23 is 2 vCPU / 4 GB."
  type        = string
  default     = "cx23"
}

variable "location" {
  description = "Hetzner location, e.g. fsn1, nbg1, hel1, ash, hil."
  type        = string
  default     = "nbg1"
}

variable "image" {
  description = "Hetzner image name."
  type        = string
  default     = "ubuntu-24.04"
}

variable "enable_backups" {
  description = "Enable Hetzner's automatic server backups. Off by default; restic covers backups."
  type        = bool
  default     = false
}

variable "ssh_public_key_path" {
  description = "Path to the OpenSSH public key injected into the server."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "deploy_user" {
  description = "Non-root user for SSH and deployments."
  type        = string
  default     = "deploy"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]*$", var.deploy_user))
    error_message = "deploy_user must be a valid Linux username."
  }
}

variable "ssh_port" {
  description = "SSH port. Kept at 22 because the port is only reachable over Tailscale or bootstrap CIDRs."
  type        = number
  default     = 22

  validation {
    condition     = var.ssh_port > 0 && var.ssh_port <= 65535
    error_message = "ssh_port must be between 1 and 65535."
  }
}

variable "ssh_source_cidrs" {
  description = "Temporary public SSH sources for bootstrap or non-Tailscale access. Empty means no public SSH."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.ssh_source_cidrs : can(cidrhost(cidr, 0))])
    error_message = "ssh_source_cidrs must contain valid CIDR blocks."
  }
}

variable "tailscale_authkey" {
  description = "Pre-authorized Tailscale auth key for the server. Use a non-ephemeral key; empty disables Tailscale and requires ssh_source_cidrs."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tailscale_hostname" {
  description = "Tailscale node name. Defaults to var.name."
  type        = string
  default     = ""
}

variable "tailscale_ssh" {
  description = "Enable Tailscale SSH (tailscale up --ssh). Regular sshd stays available over the tailnet."
  type        = bool
  default     = false
}

variable "allow_tailscale_udp" {
  description = "Allow inbound UDP 41641 for direct Tailscale connections."
  type        = bool
  default     = true
}

variable "swap_size_mb" {
  description = "Swap file size in MB. 0 disables swap."
  type        = number
  default     = 2048

  validation {
    condition     = var.swap_size_mb >= 0
    error_message = "swap_size_mb must be zero or greater."
  }
}

variable "timezone" {
  description = "Server timezone."
  type        = string
  default     = "UTC"
}

variable "labels" {
  description = "Extra Hetzner labels."
  type        = map(string)
  default     = {}
}

variable "dns_zone" {
  description = "Porkbun authoritative DNS zone without a trailing dot."
  type        = string
}

variable "app_subdomain" {
  description = "Subdomain for the shared auth service."
  type        = string
  default     = "auth"
}

variable "ses_mail_subdomain" {
  description = "Subdomain used by the SES sending identity."
  type        = string
  default     = "mail"
}

variable "ses_dkim_tokens" {
  description = "SES DKIM tokens whose CNAME records should exist under the SES mail subdomain."
  type        = list(string)
  default     = []
}
