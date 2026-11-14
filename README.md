# yz-infra

Shared infrastructure for small, self-hosted SaaS products on one Hetzner VPS.

- **OpenTofu** creates the server and firewall. `cloud-init` injects the deploy key and runs an idempotent hardening script.
- **Tailscale-only SSH**: no public port 22 after bootstrap. The only public application ingress is TCP 80/443 through Traefik.
- **Traefik v3** is the only public-facing container. It discovers apps through Docker labels on the shared external `proxy` network.
- **Per-app repos** own their Dockerfile, compose file, `.env.example`, and deploy caller. Production `.env` files stay on the server.

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

- [OpenTofu](https://opentofu.org/) 1.6 or newer (`tofu`). The committed lock file contains OpenTofu registry hashes; Terraform users should delete `tofu/.terraform.lock.hcl` and run `terraform init -upgrade` to regenerate it.
- A Hetzner Cloud API token with read/write access to the project.
- Tailscale installed on your workstation, a Tailscale account, and a **pre-authorized, tagged** auth key for the server. Suggested tag: `tag:server`. Use a **non-ephemeral** key: ephemeral nodes are removed after inactivity, which strands the VPS and can change its Tailscale IP after a rejoin.
- A Tailscale OAuth client (client ID and secret) tagged `tag:ci` for GitHub Actions deploys. Ephemeral keys are appropriate for these short-lived CI nodes. The ACL must allow `tag:ci` to reach `tag:server` on port 22.
- `jq` on your workstation for the Tailscale status check.
- A Cloudflare R2 bucket and an S3 API token scoped to it with Object Read & Write.
- An SSH key pair on your machine. The public key is injected at server creation.
- A domain whose DNS you control. Point app hostnames at the server IP manually for now (see "Out of scope").
- Strongly recommended for the first boot: your current public IP in CIDR form, so a failed Tailscale join does not require rescue mode.

## 1. First boot

```sh
export HCLOUD_TOKEN='...'
export TF_VAR_tailscale_authkey='tskey-auth-...'

cp tofu/terraform.tfvars.example tofu/terraform.tfvars
# Edit tofu/terraform.tfvars. Set ssh_source_cidrs to your current IP/32 for the
# first boot. With no Tailscale key and no CIDR, the plan fails by design; if
# the join also fails, recovery requires Hetzner rescue mode.
#   ssh_source_cidrs = ["203.0.113.10/32"]

tofu -chdir=tofu init
tofu -chdir=tofu plan -out=tfplan
tofu -chdir=tofu apply tfplan
```

Use `tofu -chdir=tofu output server_ipv4` and `server_ipv6` for DNS records. Give cloud-init a few minutes; the hardening script waits up to 5 minutes for Tailscale, then confirm the backend is actually running before relying on it:

```sh
tailscale status --json | jq -r '.BackendState'
ssh deploy@<tailscale-ip> 'sudo cloud-init status --wait; sudo tail -n 80 /var/log/yz-harden.log'
```

If the join failed **and** you set `ssh_source_cidrs`, the hardening script opens public SSH as a fallback. Use the public IP in that case:

```sh
ssh deploy@<server_ipv4> 'sudo cloud-init status --wait; sudo tail -n 80 /var/log/yz-harden.log'
```

The fallback is opened only when the script cannot confirm Tailscale is `Running`. Once Tailscale is up, UFW removes the public SSH rule. If Tailscale recovers after a failed run, re-run `harden.sh` so UFW deletes the stale fallback:

```sh
ssh deploy@<tailscale-ip> 'sudo /usr/local/sbin/yz-harden.sh'
ssh deploy@<tailscale-ip> 'sudo ufw status verbose'
```

Once Tailscale works, remove the bootstrap path and apply the firewall change:

```hcl
# tofu/terraform.tfvars
ssh_source_cidrs = []
```

```sh
tofu -chdir=tofu apply
```

The Hetzner firewall no longer allows public 22. Re-running `harden.sh` is safe; cloud-init only runs it once. To apply script changes later:

```sh
scp host/harden.sh deploy@<tailscale-ip>:/tmp/yz-harden.sh
ssh deploy@<tailscale-ip> 'sudo bash /tmp/yz-harden.sh'
```

The script reads `/etc/yz-infra/bootstrap.env` and clears the Tailscale auth key after a successful join. The server uses a non-ephemeral key, so the node survives inactivity. If the node is removed from the tailnet, the cleared key cannot rejoin it; use Hetzner rescue mode to fix access, then add a new key. Adding `ssh_source_cidrs` alone only changes the Hetzner firewall; it does not bypass UFW.

## 2. Start Traefik once

DNS for every app hostname must point at the server before the first certificate request. Point records directly at the server IP (Cloudflare "DNS only") for HTTP-01 issuance. A proxied Cloudflare record with Full (strict) fails before Traefik has a valid origin certificate; use DNS-only for the first issuance, then switch to proxied Full (strict) once the certificate exists.

```sh
rsync -az --exclude '.env' --exclude 'acme.json' --exclude 'backups/' proxy/ deploy@<tailscale-ip>:/srv/proxy/
ssh deploy@<tailscale-ip>
cd /srv/proxy
cp .env.example .env
chmod 600 .env
# Set ACME_EMAIL. Leave ACME_CA_SERVER on production unless testing.
nano .env
docker compose up -d
docker compose ps
```

For later updates, use `scripts/sync-stack.sh <tailscale-ip> proxy`. It excludes `.env`, `acme.json`, and `backups/` so a local copy cannot overwrite server state.

Only `traefik` publishes ports. `socket-proxy` is internal. The Traefik dashboard is disabled. Check logs with:

```sh
docker compose logs -f traefik
```

If you need to test certificate issuance without burning production rate limits, set `ACME_CA_SERVER` to the staging directory in `.env`, bring Traefik up, verify, then switch back to production and recreate the certificate volume:

```sh
cd /srv/proxy
docker compose down
docker volume rm proxy-letsencrypt
docker compose up -d
```

## 3. Start the ops stack

```sh
rsync -az --exclude '.env' --exclude 'backups/' ops/ deploy@<tailscale-ip>:/srv/ops/
ssh deploy@<tailscale-ip> 'cd /srv/ops && docker compose up -d'
```

For later updates, use `scripts/sync-stack.sh <tailscale-ip> ops`.

Both services bind to `127.0.0.1`, so reach them through an SSH tunnel over Tailscale:

```sh
ssh -L 3001:127.0.0.1:3001 -L 9999:127.0.0.1:9999 deploy@<tailscale-ip>
# Uptime Kuma: http://localhost:3001
# Dozzle:      http://localhost:9999
```

Configure Uptime Kuma monitors from its UI. They are not in git unless you export them.

### Backups (restic)

The host script installs `restic`. Backups cover `/srv/apps`, `/srv/proxy`, `/srv/ops`, and `/etc/yz-infra`, except `/etc/yz-infra/restic.env` and `/etc/yz-infra/bootstrap.env` (keep the restic credentials in a password manager; the bootstrap file can contain the Tailscale key if a join failed). The example target is **Cloudflare R2** over its S3-compatible API. Swap the repository URL for B2 or SFTP if you prefer; those backends need different credentials (`B2_ACCOUNT_ID`/`B2_ACCOUNT_KEY`, or an SSH key and known_hosts).

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

The timer runs daily at 03:15 with up to 5 minutes of jitter. It calls `/srv/apps/*/backup.sh`, `/srv/proxy/backup.sh`, and `/srv/ops/backup.sh` first, then snapshots the data directories, applies the retention policy, and pings Healthchecks.io when configured. A failed run pings the `/fail` endpoint. The proxy hook stops Traefik briefly and archives its certificate volume; the ops hook stops Uptime Kuma briefly and archives its data volume. A failing app hook is logged and the host snapshot still runs, but the whole backup run is marked failed.

Test a restore at least once, into a temporary directory:

```sh
ssh deploy@<tailscale-ip> 'sudo bash -c "set -a; . /etc/yz-infra/restic.env; set +a; install -d -m 0700 /tmp/restore && restic restore latest --target /tmp/restore"'
```

Remove `/tmp/restore` after checking the files. For a real restore, stop the affected stacks first, restore into a staging directory, copy the app/proxy/ops files back with the correct ownership, extract `backups/acme.tar.gz` and `backups/uptime-kuma.tar.gz` into fresh volumes, then start the stacks again. Restoring app database dumps is app-specific; follow the app's own runbook.

The repo is encrypted, but it contains `.env` files. Protect the restic password like a production secret.

## 4. Onboard an app

Each app is a separate repo. Copy `apps/example/` as a starting point.

1. **Compose contract.** The app's `compose.yaml` must:
   - set a unique top-level `name:` (usually the app name);
   - join the external `proxy` network;
   - publish no host ports;
   - set Traefik labels for its hostname;
   - define a healthcheck when the app has a health endpoint;
   - set a JSON log driver with `max-size` and `max-file`.
2. **Image contract.** The app's Docker workflow must push `sha-<7>` tags to GHCR. The deploy workflow defaults to that tag. Use immutable tags; `latest` works mechanically but is not recommended.
3. **Server env.** Create `/srv/apps/<app>/.env` once on the server from the app's `.env.example`, with mode `0600`. The deploy workflow copies the compose file and an optional `backup.sh` at the repo root; secrets stay on the server.
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
      # Must be public and unauthenticated; leave empty for internal-only apps.
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

If the app uses a database, add an executable `backup.sh` next to its compose file. The deploy workflow copies it when it exists at the repo root and removes the remote copy when it disappears from the repo. The host backup job runs every `/srv/apps/*/backup.sh` before snapshotting. These hooks execute as root, so app-repo write access is effectively host-root access; require branch protection and review. Named Docker volumes are not copied automatically, so the hook must dump or archive them. See `apps/example/backup.sh.example`.

### First deploy

Create the app directory and `.env` on the server before the first workflow run:

```sh
ssh deploy@<tailscale-ip> 'mkdir -p /srv/apps/example'
scp apps/example/.env.example deploy@<tailscale-ip>:/srv/apps/example/.env.example
ssh deploy@<tailscale-ip> 'cd /srv/apps/example && cp .env.example .env && chmod 600 .env'
ssh -t deploy@<tailscale-ip> 'cd /srv/apps/example && nano .env'
```

Set `APP_DOMAIN` and `APP_PORT` in that file before the first deploy, along with the app's secrets. Then trigger deployment by pushing/merging to `main` so the `Docker` workflow runs, or re-run the `Docker` workflow; a `workflow_run` caller has no manual "Run workflow" button. The workflow copies the compose file and an optional `backup.sh`, logs in to GHCR if a token is provided, pulls the pinned image, and runs `docker compose up -d --remove-orphans --wait`.

## Operating notes

- **No public SSH after bootstrap.** Port 22 is reachable only over Tailscale. The Hetzner firewall also blocks 22 unless you explicitly add bootstrap CIDRs.
- **Deploys are brief restarts.** Compose replaces containers; there is no blue/green. A few seconds of downtime per deploy is expected for personal tools.
- **Disk pressure.** Docker log rotation is set in `/etc/docker/daemon.json`; app compose files should set their own limits too. Watch disk with Uptime Kuma, or add Beszel/Netdata later.
- **Automatic reboots.** `unattended-upgrades` reboots at 04:30 when required. Containers restart because of `restart: unless-stopped`.
- **Traefik state.** Certificates live in the `proxy-letsencrypt` volume and are included in the proxy backup hook. Repeated deletion can hit Let's Encrypt rate limits.
- **Socket access.** The Docker socket proxy reduces the API surface, but anything with socket access is effectively root on the host. Keep `socket-proxy` internal and do not expose it.
- **Passwordless sudo.** The `deploy` user gets `NOPASSWD:ALL` because admin commands and the backup hooks need root without an interactive password. The deploy password is locked, so do not remove the sudoers drop-in unless you first create another password-capable admin path. Membership in the `docker` group is already root-equivalent.
- **Secrets in state.** The Tailscale auth key is in OpenTofu state and in the server's cloud-init metadata. Use a non-ephemeral server key, rotate it, and encrypt/back up local state as a secret before adding collaborators.
- **Cloud-init is one-shot.** `user_data` is ignored after creation, so changing `harden.sh`, the deploy key, or Tailscale settings in `terraform.tfvars` does not update an existing server. Re-run `harden.sh` over SSH, or rebuild the server deliberately.
- **Rescue mode.** If Tailscale and SSH are both unavailable, use Hetzner rescue mode: enable rescue in the console, reboot, mount the disk, chroot, add the deploy key or start `tailscaled`, then reboot. Adding `ssh_source_cidrs` alone only changes the Hetzner firewall; it does not bypass UFW.

## Out of scope / deliberately deferred

These are known gaps, not oversights:

- **Remote OpenTofu state and locking.** Local state only for now. Back up `tofu/terraform.tfstate` securely (it contains the Tailscale key), and add an encrypted S3/OpenTofu backend before more than one operator.
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

- [ ] `tofu plan` shows only the intended server, firewall, and SSH key.
- [ ] Cloud-init finished without errors: `cloud-init status --long`.
- [ ] `tailscale status --json | jq -r .BackendState` reports `Running`.
- [ ] `ssh deploy@<tailscale-ip>` works and `sudo -n true` succeeds.
- [ ] After removing the bootstrap CIDR, `nc -vz <public-ip> 22` fails and `ufw status verbose` shows no public 22 rule.
- [ ] Traefik serves a test hostname with a valid certificate.
- [ ] Uptime Kuma and Dozzle are reachable only through the tunnel.
- [ ] App `.env` files are mode `0600`.
- [ ] A restic backup ran and a restore was tested.
- [ ] `docker inspect <container> --format '{{json .HostConfig.LogConfig}}'` shows the log limits.
- [ ] Re-running `harden.sh` makes no unexpected changes.
