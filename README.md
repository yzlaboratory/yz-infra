# yz-infra

Shared infrastructure for small, self-hosted SaaS products on one Hetzner VPS.

- **OpenTofu** creates the server and firewall. `cloud-init` injects the deploy key and runs an idempotent hardening script.
- **Tailscale-only SSH**: no public port 22. The only public application ingress is TCP 80/443 through Traefik.
- **Traefik v3** is the only public-facing container. It discovers apps through Docker labels on the shared external `proxy` network.
- **Per-app repos** own their Dockerfile, compose file, `.env`, and deploy workflow. This repo owns the host, proxy, and cross-cutting operations.

## Layout

```text
yz-infra/
├── tofu/                       OpenTofu: server, firewall, cloud-init
├── host/harden.sh              idempotent host hardening (run by cloud-init)
├── proxy/                      Traefik + Docker socket proxy
│   ├── compose.yaml
│   ├── .env.example
│   ├── backup.sh
│   └── dynamic/middlewares.yaml
├── apps/example/               copy this into a new app repo
│   ├── compose.yaml
│   ├── .env.example
│   └── backup.sh.example
├── ops/                        one instance for the whole box
│   ├── compose.yaml            Uptime Kuma + Dozzle
│   ├── backup.sh
│   ├── restic/                 backup script and env example
│   └── systemd/                daily backup timer
├── scripts/sync-stack.sh       copy proxy/ or ops/ to the server
└── .github/workflows/deploy.yml  reusable app deploy workflow
```

## Architecture

```text
Internet
   │  :80 / :443
   ▼
Hetzner firewall (allows 80, 443, optional 22 from bootstrap CIDRs, UDP 41641)
   │
   ▼
Traefik (Docker, proxy network) ──labels──► app containers (no published ports)
   │
   └── Let's Encrypt HTTP-01 certificates in the proxy-letsencrypt volume

SSH: your machine ──Tailscale──► tailscale0 on the VPS ──► sshd (deploy user)
```

The Hetzner firewall is the outer boundary. UFW is defense in depth. Docker publishes ports by bypassing UFW, so the Hetzner firewall is what actually prevents an accidentally published app port from being reachable.

## Prerequisites

- [OpenTofu](https://opentofu.org/) 1.6 or newer (`tofu`). The lock file is OpenTofu's; Terraform users can run `terraform init` to regenerate it.
- A Hetzner Cloud API token with read/write access to the project.
- Tailscale installed on your workstation, a Tailscale account, and an **ephemeral, pre-authorized, tagged** auth key for the server. Suggested tag: `tag:server`.
- A Tailscale OAuth client (client ID and secret) tagged `tag:ci` for GitHub Actions deploys. The ACL must allow `tag:ci` to reach `tag:server` on port 22.
- An SSH key pair on your machine. The public key is injected at server creation.
- A domain whose DNS you control. Point app hostnames at the server IP manually for now (see "Out of scope").
- Optional for bootstrap safety: your current public IP in CIDR form.

## 1. First boot

```sh
export HCLOUD_TOKEN='...'
export TF_VAR_tailscale_authkey='tskey-auth-...'

cp tofu/terraform.tfvars.example tofu/terraform.tfvars
# Edit tofu/terraform.tfvars. Set ssh_source_cidrs to your current IP/32 for the
# first boot if you want a fallback path in case Tailscale fails to join:
#   ssh_source_cidrs = ["203.0.113.10/32"]

tofu -chdir=tofu init
tofu -chdir=tofu plan -out=tfplan
tofu -chdir=tofu apply tfplan
```

Use `tofu -chdir=tofu output server_ipv4` and `server_ipv6` for DNS records. Wait for the node to appear in Tailscale (usually 2–5 minutes), then check cloud-init over the tailnet:

```sh
tailscale status | grep yz-vps
ssh deploy@<tailscale-ip> 'sudo cloud-init status --wait; sudo tail -n 80 /var/log/yz-harden.log'
```

If the Tailscale join failed **and** you set `ssh_source_cidrs`, the hardening script opens public SSH as a fallback. Use the public IP in that case:

```sh
ssh deploy@<server_ipv4> 'sudo cloud-init status --wait; sudo tail -n 80 /var/log/yz-harden.log'
```

The public path is deliberately closed once Tailscale is up, so it is not available when the join succeeded but your local Tailscale client is broken. In that case use another tailnet device or the Hetzner console.

Once Tailscale works, remove the bootstrap path and apply the firewall change:

```hcl
# tofu/terraform.tfvars
ssh_source_cidrs = []
```

```sh
tofu -chdir=tofu apply
```

The server's public port 22 is now closed. Re-running `harden.sh` is safe; cloud-init only runs it once. To apply script changes later:

```sh
scp host/harden.sh deploy@<tailscale-ip>:/tmp/yz-harden.sh
ssh deploy@<tailscale-ip> 'sudo bash /tmp/yz-harden.sh'
```

The script reads `/etc/yz-infra/bootstrap.env`. It clears the Tailscale auth key after a successful join, so a re-run cannot re-join a node that has been removed. Recover through the Hetzner console if that happens.

## 2. Start Traefik once

DNS for every app hostname must point at the server before the first certificate request. Point records directly at the server IP (Cloudflare "DNS only") for HTTP-01 issuance. A proxied Cloudflare record can work in Full (strict) mode, but it adds a failure mode; start with DNS only.

```sh
rsync -az proxy/ deploy@<tailscale-ip>:/srv/proxy/
ssh deploy@<tailscale-ip>
cd /srv/proxy
cp .env.example .env
# Set ACME_EMAIL. Leave ACME_CA_SERVER on production unless testing.
nano .env
docker compose up -d
docker compose ps
```

Only `traefik` publishes ports. `socket-proxy` is internal. The Traefik dashboard is disabled. Check logs with:

```sh
docker compose logs -f traefik
```

If you need to test certificate issuance without burning production rate limits, set `ACME_CA_SERVER` to the staging directory in `.env`, bring Traefik up, verify, then switch back and remove the `proxy-letsencrypt` volume so production certificates are issued cleanly.

## 3. Start the ops stack

```sh
rsync -az ops/ deploy@<tailscale-ip>:/srv/ops/
ssh deploy@<tailscale-ip> 'cd /srv/ops && docker compose up -d'
```

Both services bind to `127.0.0.1`, so reach them through an SSH tunnel over Tailscale:

```sh
ssh -L 3001:127.0.0.1:3001 -L 9999:127.0.0.1:9999 deploy@<tailscale-ip>
# Uptime Kuma: http://localhost:3001
# Dozzle:      http://localhost:9999
```

Configure Uptime Kuma monitors from its UI. They are not in git unless you export them.

### Backups (restic)

The host script installs `restic`. Backups cover `/srv/apps`, `/srv/proxy`, `/srv/ops`, and `/etc/yz-infra`, except `/etc/yz-infra/restic.env` (keep that file in a password manager). The example target is **Cloudflare R2** over its S3-compatible API. Swap the repository URL for B2 or SFTP if you prefer; restic supports all three.

```sh
# 1. Install the script and units
scp ops/restic/backup.sh deploy@<tailscale-ip>:/tmp/yz-backup.sh
scp ops/systemd/yz-backup.service ops/systemd/yz-backup.timer deploy@<tailscale-ip>:/tmp/
ssh deploy@<tailscale-ip> 'sudo install -m 0755 /tmp/yz-backup.sh /usr/local/sbin/yz-backup.sh && sudo install -m 0644 /tmp/yz-backup.service /tmp/yz-backup.timer /etc/systemd/system/'

# 2. Create the encrypted repo config. Start from the example and keep it 0600.
scp ops/restic/restic.env.example deploy@<tailscale-ip>:/tmp/restic.env
ssh deploy@<tailscale-ip> 'sudo install -d -m 0700 /etc/yz-infra && sudo install -m 0600 /tmp/restic.env /etc/yz-infra/restic.env'
ssh -t deploy@<tailscale-ip> 'sudoedit /etc/yz-infra/restic.env'

# 3. Initialize the repo once
ssh deploy@<tailscale-ip> 'sudo bash -c "set -a; . /etc/yz-infra/restic.env; set +a; restic init"'

# 4. Enable the timer
ssh deploy@<tailscale-ip> 'sudo systemctl daemon-reload && sudo systemctl enable --now yz-backup.timer && sudo systemctl start yz-backup.service'

# 5. Verify and test a restore
ssh deploy@<tailscale-ip> 'sudo bash -c "set -a; . /etc/yz-infra/restic.env; set +a; restic snapshots"'
```

The timer runs daily at 03:15 with up to 5 minutes of jitter. It calls `/srv/apps/*/backup.sh`, `/srv/proxy/backup.sh`, and `/srv/ops/backup.sh` first, then snapshots the data directories, applies the retention policy, and pings Healthchecks.io when configured. A failed run pings the `/fail` endpoint. The proxy hook archives Traefik's certificate volume; the ops hook archives Uptime Kuma's data volume.

Test a restore at least once, into a temporary directory:

```sh
ssh deploy@<tailscale-ip> 'sudo bash -c "set -a; . /etc/yz-infra/restic.env; set +a; mkdir -p /tmp/restore && restic restore latest --target /tmp/restore"'
```

The repo is encrypted, but it contains `.env` files. Protect the restic password like a production secret.

## 4. Onboard an app

Each app is a separate repo. Copy `apps/example/` as a starting point.

1. **Compose contract.** The app's `compose.yaml` must:
   - join the external `proxy` network;
   - publish no host ports;
   - set Traefik labels for its hostname;
   - define a healthcheck when the app has a health endpoint;
   - set a JSON log driver with `max-size` and `max-file`.
2. **Image contract.** The app's Docker workflow must push `sha-<7>` tags to GHCR. The deploy workflow defaults to that tag. Pinning `latest` is not supported.
3. **Server env.** Create `/srv/apps/<app>/.env` once on the server from the app's `.env.example`. The deploy workflow copies the compose file and an optional `backup.sh` at the repo root; secrets stay on the server.
4. **DNS.** Add an A/AAAA record for the app hostname pointing at the server's public IP.
5. **Deploy.** Call the reusable workflow from the app repo:

```yaml
name: Deploy

on:
  workflow_run:
    workflows: [Docker]
    types: [completed]
    branches: [main]

permissions:
  contents: read

jobs:
  deploy:
    if: github.event.workflow_run.conclusion == 'success'
    uses: yzlaboratory/yz-infra/.github/workflows/deploy.yml@main
    with:
      app_name: example
      image: ghcr.io/yzlaboratory/example
      # workflow_run runs on the default branch, so point the deploy at the
      # commit that was actually built.
      sha: ${{ github.event.workflow_run.head_sha }}
      ref: ${{ github.event.workflow_run.head_sha }}
      compose_file: compose.yaml
      health_url: https://example.example.com/healthz
    secrets:
      SSH_HOST: ${{ secrets.SSH_HOST }}          # Tailscale IP of the VPS
      SSH_USER: ${{ secrets.SSH_USER }}          # deploy
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
      TS_OAUTH_CLIENT_ID: ${{ secrets.TS_OAUTH_CLIENT_ID }}
      TS_OAUTH_SECRET: ${{ secrets.TS_OAUTH_SECRET }}
      GHCR_TOKEN: ${{ secrets.GHCR_TOKEN }}      # read:packages PAT
      GHCR_USER: ${{ secrets.GHCR_USER }}
```

Store `SSH_HOST` as the server's Tailscale IP (for example `100.x.y.z`), not its public IP. The workflow joins the tailnet as `tag:ci`, so the Tailscale ACL must allow `tag:ci` to reach `tag:server` on port 22. Pin the `uses:` reference to a commit SHA once the workflow stabilizes.

If the app repo is in the same GitHub organization and the reusable workflow is accessible, `secrets: inherit` works too, as long as the secret names match.

### Backups for an app

If the app uses a database, add an executable `backup.sh` next to its compose file. The deploy workflow copies it when it exists at the repo root. The host backup job runs every `/srv/apps/*/backup.sh` before snapshotting. Named Docker volumes are not copied automatically, so the hook must dump or archive them. See `apps/example/backup.sh.example`.

### First deploy

Create the app directory and `.env` on the server before the first workflow run:

```sh
ssh deploy@<tailscale-ip> 'mkdir -p /srv/apps/example'
scp apps/example/.env.example deploy@<tailscale-ip>:/srv/apps/example/.env.example
ssh deploy@<tailscale-ip> 'cd /srv/apps/example && cp .env.example .env'
ssh -t deploy@<tailscale-ip> 'cd /srv/apps/example && nano .env'
```

Then run the app's deploy workflow. The workflow copies the compose file and an optional `backup.sh`, logs in to GHCR if a token is provided, pulls the pinned image, and runs `docker compose up -d --remove-orphans --wait`.

## Operating notes

- **No public SSH.** Port 22 is reachable only over Tailscale. The Hetzner firewall also blocks 22 unless you explicitly add bootstrap CIDRs.
- **Deploys are brief restarts.** Compose replaces containers; there is no blue/green. A few seconds of downtime per deploy is expected for personal tools.
- **Disk pressure.** Docker log rotation is set in `/etc/docker/daemon.json`; app compose files should set their own limits too. Watch disk with Uptime Kuma or Beszel.
- **Automatic reboots.** `unattended-upgrades` reboots at 04:30 when required. Containers restart because of `restart: unless-stopped`.
- **Traefik state.** Certificates live in the `proxy-letsencrypt` volume. Back it up; repeated deletion can hit Let's Encrypt rate limits.
- **Socket access.** The Docker socket proxy reduces the API surface, but anything with socket access is effectively root on the host. Keep `socket-proxy` internal and do not expose it.
- **Passwordless sudo.** The `deploy` user gets `NOPASSWD:ALL` because admin commands and the backup hooks need root without an interactive password. The compensating controls are key-only SSH over Tailscale and no public port 22. Remove the sudoers drop-in if you don't need it; note that membership in the `docker` group is already root-equivalent.
- **Secrets in state.** The Tailscale auth key is in OpenTofu state and in the server's cloud-init metadata. Use an ephemeral key, rotate it, and encrypt state before adding collaborators.
- **Cloud-init is one-shot.** `user_data` is ignored after creation, so changing `harden.sh`, the deploy key, or Tailscale settings in `terraform.tfvars` does not update an existing server. Re-run `harden.sh` over SSH, or rebuild the server deliberately.

## Out of scope / deliberately deferred

These are known gaps, not oversights:

- **Remote OpenTofu state and locking.** Local state only for now. Add an encrypted S3/OpenTofu backend before more than one operator.
- **DNS automation.** Records are manual. Add a Porkbun or Cloudflare provider when the hostname list stops changing by hand.
- **Central logging and metrics.** No Loki, Grafana, Beszel, or Netdata. Dozzle plus Uptime Kuma is the starting point.
- **WAF/DDoS beyond provider defaults.** Hetzner and optional Cloudflare only. No CrowdSec or blocklist cron.
- **Image pruning.** No scheduled `docker image prune`; add a timer when disk usage becomes a problem.
- **Secrets management.** No sops/age or vault. `.env` files live on the server only.
- **High availability.** One VPS is a single point of failure by design.
- **Email.** Use SES/Resend/Postmark. Do not run a mail server here.
- **Tailscale ACL automation.** ACLs are managed in the Tailscale admin console.
- **Windows bootstrap.** This scaffold assumes a Unix-like workstation.
- **Zero-downtime deploys.** Add Kamal or a blue/green setup only if an app becomes revenue-critical.

## Cost sketch

One Hetzner `cx22` (2 vCPU, 4 GB) is roughly €4–8/month depending on location and VAT. Cloudflare R2 includes 10 GB of storage for free and has no egress fees; small backups cost a few cents. Hetzner's own backup option is disabled by default (`enable_backups = false`) because restic already covers it. Prices change; check the providers.

## Review checklist

Before trusting this in production:

- [ ] `tofu plan` shows only the intended server and firewall.
- [ ] Cloud-init finished without errors: `cloud-init status --long`.
- [ ] `ssh deploy@<tailscale-ip>` works and `sudo -n true` succeeds.
- [ ] Public port 22 is closed: `nc -vz <public-ip> 22` fails.
- [ ] Traefik serves a test hostname with a valid certificate.
- [ ] Uptime Kuma and Dozzle are reachable only through the tunnel.
- [ ] A restic backup ran and a restore was tested.
- [ ] `docker inspect <container> --format '{{json .HostConfig.LogConfig}}'` shows the log limits.
- [ ] Re-running `harden.sh` makes no unexpected changes.
