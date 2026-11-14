#!/usr/bin/env bash
# yz-infra host hardening for Ubuntu 24.04.
#
# Idempotent: safe to re-run. cloud-init runs it once on first boot; run it
# again over SSH after changing this file.
#
# Configuration comes from /etc/yz-infra/bootstrap.env when present. The
# defaults below are for a standalone run; a cloud-init run always supplies
# the environment file.
set -euo pipefail

LOG_FILE=/var/log/yz-harden.log
install -d -m 0755 "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { printf '[yz-harden] %s\n' "$*"; }
die() { printf '[yz-harden] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run as root"
[[ -r /etc/os-release ]] || die "missing /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || log "warning: tested on Ubuntu 24.04; found ${PRETTY_NAME:-unknown}"

if [[ -r /etc/yz-infra/bootstrap.env ]]; then
  # shellcheck disable=SC1091
  . /etc/yz-infra/bootstrap.env
fi

DEPLOY_USER=${DEPLOY_USER:-deploy}
SSH_PORT=${SSH_PORT:-22}
ENABLE_TAILSCALE=${ENABLE_TAILSCALE:-0}
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY:-}
TAILSCALE_HOSTNAME=${TAILSCALE_HOSTNAME:-$(hostname -s)}
TAILSCALE_SSH=${TAILSCALE_SSH:-0}
SWAP_SIZE_MB=${SWAP_SIZE_MB:-2048}
TIMEZONE=${TIMEZONE:-UTC}

[[ -n ${DEPLOY_SSH_PUBLIC_KEY:-} ]] || die "DEPLOY_SSH_PUBLIC_KEY is required"
[[ ${DEPLOY_USER} =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid DEPLOY_USER"
[[ ${DEPLOY_USER} != "root" ]] || die "DEPLOY_USER must not be root"
[[ ${SSH_PORT} =~ ^[0-9]+$ ]] || die "invalid SSH_PORT"
[[ ${SWAP_SIZE_MB} =~ ^[0-9]+$ ]] || die "invalid SWAP_SIZE_MB"

apt_update() {
  DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 update -qq
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"
}

log "installing base packages"
apt_update
apt_install curl ca-certificates gnupg jq ufw restic openssh-client iptables

if ! printf '%s\n' "$DEPLOY_SSH_PUBLIC_KEY" | ssh-keygen -l -f - >/dev/null 2>&1; then
  die "DEPLOY_SSH_PUBLIC_KEY is not a valid OpenSSH public key"
fi

if ! timedatectl list-timezones | grep -Fx -- "$TIMEZONE" >/dev/null; then
  die "invalid TIMEZONE: $TIMEZONE"
fi
timedatectl set-timezone "$TIMEZONE"
timedatectl set-ntp true || log "warning: could not enable NTP"

log "installing Docker"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

DOCKER_CODENAME=${VERSION_CODENAME:-}
[[ -n $DOCKER_CODENAME ]] || die "VERSION_CODENAME missing from /etc/os-release"
cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $DOCKER_CODENAME stable
EOF

apt_update
apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "configuring Docker log rotation"
install -d -m 0755 /etc/docker
DAEMON_JSON=/etc/docker/daemon.json
DAEMON_TMP=$(mktemp)
cat > "$DAEMON_TMP" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF
if [[ -f $DAEMON_JSON ]] && cmp -s "$DAEMON_TMP" "$DAEMON_JSON"; then
  rm -f "$DAEMON_TMP"
else
  install -m 0644 "$DAEMON_TMP" "$DAEMON_JSON"
  rm -f "$DAEMON_TMP"
  systemctl restart docker 2>/dev/null || true
fi
systemctl enable --now docker

log "creating deploy user"
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups sudo "$DEPLOY_USER"
else
  log "user $DEPLOY_USER already exists"
fi
usermod -aG sudo "$DEPLOY_USER"
if getent group docker >/dev/null 2>&1; then
  usermod -aG docker "$DEPLOY_USER"
else
  log "warning: docker group is missing; deploy user cannot run docker yet"
fi
passwd -l "$DEPLOY_USER" >/dev/null 2>&1 || true
DEPLOY_GROUP=$(id -gn "$DEPLOY_USER")

install -d -m 0700 -o "$DEPLOY_USER" -g "$DEPLOY_GROUP" "/home/$DEPLOY_USER/.ssh"
AUTH_KEYS="/home/$DEPLOY_USER/.ssh/authorized_keys"
touch "$AUTH_KEYS"
chown "$DEPLOY_USER:$DEPLOY_GROUP" "$AUTH_KEYS"
chmod 0600 "$AUTH_KEYS"
if ! grep -qxF "$DEPLOY_SSH_PUBLIC_KEY" "$AUTH_KEYS"; then
  printf '%s\n' "$DEPLOY_SSH_PUBLIC_KEY" >> "$AUTH_KEYS"
fi

log "configuring passwordless sudo for $DEPLOY_USER"
SUDOERS=/etc/sudoers.d/90-yz-deploy
SUDOERS_TMP=$(mktemp)
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DEPLOY_USER" > "$SUDOERS_TMP"
if ! visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
  rm -f "$SUDOERS_TMP"
  die "generated sudoers file is invalid"
fi
install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS"
rm -f "$SUDOERS_TMP"

log "configuring sshd"
install -d -m 0755 /etc/ssh/sshd_config.d
# 00- sorts before cloud-init's 50-cloud-init.conf. sshd uses the first value
# it sees for most keywords, so this file must come first.
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-yz-hardening.conf
cat > "$SSHD_DROPIN" <<EOF
# Managed by yz-infra. Do not edit.
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
UseDNS no
GSSAPIAuthentication no
MaxAuthTries 3
LoginGraceTime 20
MaxSessions 10
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
PermitTunnel no
GatewayPorts no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $DEPLOY_USER
EOF

if sshd -t; then
  if systemctl reload ssh 2>/dev/null; then
    log "sshd reloaded"
  elif systemctl reload sshd 2>/dev/null; then
    log "sshd reloaded"
  else
    systemctl restart ssh 2>/dev/null || log "warning: could not reload sshd; check manually"
  fi
else
  log "ERROR: sshd config validation failed; removing drop-in and keeping existing SSH"
  rm -f "$SSHD_DROPIN"
fi

TAILSCALE_OK=0
if [[ $ENABLE_TAILSCALE == "1" ]]; then
  log "installing Tailscale"
  install -d -m 0755 /usr/share/keyrings
  TS_CODENAME=${VERSION_CODENAME:-noble}
  curl -fsSL --retry 3 "https://pkgs.tailscale.com/stable/ubuntu/${TS_CODENAME}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL --retry 3 "https://pkgs.tailscale.com/stable/ubuntu/${TS_CODENAME}.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list
  apt_update
  apt_install tailscale
  systemctl enable --now tailscaled

  if [[ -z "$(tailscale ip -4 2>/dev/null || true)" ]]; then
    [[ -n $TAILSCALE_AUTH_KEY ]] || die "ENABLE_TAILSCALE=1 but TAILSCALE_AUTH_KEY is empty and the node is not up"
    TS_UP_ARGS=(--hostname "$TAILSCALE_HOSTNAME" --accept-routes=false)
    if [[ $TAILSCALE_SSH == "1" ]]; then
      TS_UP_ARGS+=(--ssh)
    fi
    # Pass the key through the environment so it does not appear in `ps`.
    TS_AUTHKEY="$TAILSCALE_AUTH_KEY" tailscale up "${TS_UP_ARGS[@]}" || log "warning: tailscale up failed"
  else
    log "Tailscale already has an IPv4 address"
  fi

  tailscale_ready() {
    local status
    status=$(tailscale status --json 2>/dev/null) || return 1
    printf '%s' "$status" | jq -e '.BackendState == "Running"' >/dev/null 2>&1 || return 1
    [[ -n "$(tailscale ip -4 2>/dev/null || true)" ]]
  }

  log "waiting up to 5 minutes for Tailscale to be Running"
  for _ in $(seq 1 150); do
    if tailscale_ready; then
      TAILSCALE_OK=1
      break
    fi
    sleep 2
  done

  if [[ $TAILSCALE_OK -eq 1 ]]; then
    log "Tailscale is up: $(tailscale ip -4 | head -n1)"
    # Do not leave the auth key on disk after a successful join. The key is
    # still present in cloud-init metadata and OpenTofu state; use a
    # non-ephemeral server key and rotate it.
    if [[ -f /etc/yz-infra/bootstrap.env ]]; then
      sed -i 's|^TAILSCALE_AUTH_KEY=.*|TAILSCALE_AUTH_KEY=""|' /etc/yz-infra/bootstrap.env
      chmod 0600 /etc/yz-infra/bootstrap.env
      chown root:root /etc/yz-infra/bootstrap.env
    fi
  else
    log "WARNING: Tailscale did not come up. Allowing public SSH as a fallback; the Hetzner firewall still limits sources."
  fi
else
  log "Tailscale disabled; SSH will be allowed on the public interface"
fi

log "configuring UFW"
# Docker needs forwarding between bridge interfaces. The Hetzner firewall is the
# outer boundary; UFW is defense in depth for host-level ports.
if [[ -f /etc/default/ufw ]]; then
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
fi
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp

if [[ $TAILSCALE_OK -eq 1 ]]; then
  # Remove any earlier bootstrap rule that allowed public SSH.
  ufw --force delete allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true
  ufw allow in on tailscale0 to any port "$SSH_PORT" proto tcp
  ufw allow 41641/udp
else
  ufw allow "$SSH_PORT"/tcp
fi

ufw --force enable
ufw status verbose || true

if [[ $TAILSCALE_OK -ne 1 ]]; then
  log "installing fail2ban for public SSH"
  apt_install fail2ban python3-systemd
  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 15m
maxretry = 5
backend = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $SSH_PORT
EOF
  systemctl enable --now fail2ban || log "warning: could not enable fail2ban"
  systemctl restart fail2ban || log "warning: could not restart fail2ban"
else
  log "Tailscale is up; skipping fail2ban"
fi

log "configuring unattended upgrades"
apt_install unattended-upgrades apt-listchanges
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52-yz-unattended-upgrades <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
systemctl enable --now unattended-upgrades || log "warning: could not enable unattended-upgrades"

if [[ $SWAP_SIZE_MB -gt 0 ]]; then
  if ! swapon --show=NAME --noheadings 2>/dev/null | grep -Fx '/swapfile' >/dev/null; then
    if [[ -L /swapfile ]]; then
      die "/swapfile must not be a symlink"
    fi
    if [[ ! -f /swapfile ]]; then
      log "creating ${SWAP_SIZE_MB}MB swap file"
      if ! fallocate -l "${SWAP_SIZE_MB}M" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=none
      fi
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  fi
else
  log "swap disabled (SWAP_SIZE_MB=0)"
fi

log "applying sysctl hardening"
cat > /etc/sysctl.d/99-yz-hardening.conf <<'EOF'
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
net.ipv4.tcp_syncookies = 1
# Loose reverse-path filtering avoids dropping legitimate asymmetric traffic
# from Docker bridges and Tailscale while still rejecting obvious spoofing.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
vm.swappiness = 10
EOF
sysctl --system >/dev/null

log "limiting the systemd journal"
install -d -m 0755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-yz-limits.conf <<'EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
RuntimeMaxUse=100M
EOF
systemctl restart systemd-journald || log "warning: could not restart systemd-journald"

install -d -m 0755 -o "$DEPLOY_USER" -g "$DEPLOY_GROUP" /srv/apps /srv/proxy /srv/ops
install -d -m 0700 -o root -g root /etc/yz-infra

log "hardening complete"
if [[ $TAILSCALE_OK -eq 1 ]]; then
  log "SSH: ssh ${DEPLOY_USER}@$(tailscale ip -4 | head -n1)"
else
  log "SSH: ssh -p ${SSH_PORT} ${DEPLOY_USER}@<public-ip> (the Hetzner firewall must allow your source)"
fi
log "Verify SSH from a new terminal before closing this session."
