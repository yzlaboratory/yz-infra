output "server_name" {
  description = "Hetzner server name."
  value       = hcloud_server.this.name
}

output "server_ipv4" {
  description = "Public IPv4 address. Use this for DNS A records, not for SSH."
  value       = hcloud_server.this.ipv4_address
}

output "server_ipv6" {
  description = "Public IPv6 address. Use this for DNS AAAA records."
  value       = hcloud_server.this.ipv6_address
}

output "ssh_command" {
  description = "SSH command hint. The Tailscale IP is only known after cloud-init joins the tailnet."
  value = local.tailscale_enabled ? (
    "ssh ${var.deploy_user}@<tailscale-ip>   # find it with: tailscale status"
    ) : (
    "ssh -p ${var.ssh_port} ${var.deploy_user}@${hcloud_server.this.ipv4_address}"
  )
}

output "tailscale_enabled" {
  description = "Whether cloud-init is configured to join Tailscale."
  value       = local.tailscale_enabled
}

output "firewall_name" {
  description = "Hetzner firewall name."
  value       = hcloud_firewall.this.name
}
