resource "porkbun_dns_record" "auth_a" {
  domain    = var.dns_zone
  subdomain = var.app_subdomain
  type      = "A"
  content   = hcloud_server.this.ipv4_address
  ttl       = 600
}

resource "porkbun_dns_record" "auth_aaaa" {
  domain    = var.dns_zone
  subdomain = var.app_subdomain
  type      = "AAAA"
  content   = hcloud_server.this.ipv6_address
  ttl       = 600
}

resource "porkbun_dns_record" "ses_dkim" {
  count = length(var.ses_dkim_tokens)

  domain    = var.dns_zone
  subdomain = "${var.ses_dkim_tokens[count.index]}._domainkey.${var.ses_mail_subdomain}"
  type      = "CNAME"
  content   = "${var.ses_dkim_tokens[count.index]}.dkim.amazonses.com"
  ttl       = 600
}
