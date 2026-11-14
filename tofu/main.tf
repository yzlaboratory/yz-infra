locals {
  # Keep only "type base64" from the public key. Dropping the comment avoids
  # shell/YAML quoting surprises when the key is embedded in cloud-init.
  ssh_public_key = join(" ", regex("^(\\S+)\\s+(\\S+)", trimspace(file(pathexpand(var.ssh_public_key_path)))))

  tailscale_enabled  = nonsensitive(var.tailscale_authkey != "")
  tailscale_hostname = var.tailscale_hostname != "" ? var.tailscale_hostname : var.name

  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    deploy_user        = var.deploy_user
    ssh_public_key     = local.ssh_public_key
    enable_tailscale   = local.tailscale_enabled ? "1" : "0"
    tailscale_authkey  = var.tailscale_authkey
    tailscale_hostname = local.tailscale_hostname
    tailscale_ssh      = var.tailscale_ssh ? "1" : "0"
    ssh_port           = var.ssh_port
    swap_size_mb       = var.swap_size_mb
    timezone           = var.timezone
    harden_script      = file("${path.module}/../host/harden.sh")
  })

  base_labels = {
    managed_by = "opentofu"
    project    = "yz-infra"
  }
}

resource "hcloud_ssh_key" "deploy" {
  name       = "${var.name}-deploy"
  public_key = local.ssh_public_key

  lifecycle {
    precondition {
      condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|sk-ssh-ed25519@openssh.com) ", local.ssh_public_key))
      error_message = "ssh_public_key_path must point to an OpenSSH public key."
    }
  }
}

resource "hcloud_firewall" "this" {
  name = "${var.name}-fw"

  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "ICMP diagnostics"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTP (redirect and ACME HTTP-01)"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTPS"
  }

  dynamic "rule" {
    for_each = length(var.ssh_source_cidrs) > 0 ? [1] : []
    content {
      direction   = "in"
      protocol    = "tcp"
      port        = tostring(var.ssh_port)
      source_ips  = var.ssh_source_cidrs
      description = "Temporary bootstrap SSH"
    }
  }

  dynamic "rule" {
    for_each = local.tailscale_enabled && var.allow_tailscale_udp ? [1] : []
    content {
      direction   = "in"
      protocol    = "udp"
      port        = "41641"
      source_ips  = ["0.0.0.0/0", "::/0"]
      description = "Tailscale direct connections"
    }
  }
}

resource "hcloud_server" "this" {
  name         = var.name
  image        = var.image
  server_type  = var.server_type
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.deploy.id]
  firewall_ids = [hcloud_firewall.this.id]
  backups      = var.enable_backups
  user_data    = local.cloud_init

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  labels = merge(local.base_labels, var.labels)

  lifecycle {
    # Script changes should be applied deliberately over SSH, not by rebuilding
    # the server. See the README for the re-run command.
    ignore_changes = [user_data]

    precondition {
      condition     = local.tailscale_enabled || length(var.ssh_source_cidrs) > 0
      error_message = "Set tailscale_authkey or at least one ssh_source_cidrs entry; otherwise the server has no SSH path."
    }
  }
}
