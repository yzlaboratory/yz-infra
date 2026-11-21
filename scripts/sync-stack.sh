#!/usr/bin/env bash
set -euo pipefail

HOST=${1:-}
STACK=${2:-proxy}

if [[ -z $HOST ]]; then
  echo "usage: $0 <tailscale-ip-or-host> [proxy|ops]" >&2
  exit 1
fi

case "$STACK" in
  proxy|ops) ;;
  *)
    echo "unknown stack: $STACK (expected proxy or ops)" >&2
    exit 1
    ;;
esac

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE="$REPO_ROOT/$STACK"
DEST="/srv/$STACK"

if [[ ! -d $SOURCE ]]; then
  echo "missing source directory: $SOURCE" >&2
  exit 1
fi

rsync -az --delete \
  --exclude '.env' \
  --exclude 'acme.json' \
  --exclude 'backups/' \
  "$SOURCE/" "deploy@$HOST:$DEST/"

if [[ $STACK == "ops" ]]; then
  ssh "deploy@$HOST" "sudo install -m 0755 '$DEST/restic/backup.sh' /usr/local/sbin/yz-backup.sh && sudo install -m 0755 '$DEST/restic/backup-volume.sh' /usr/local/sbin/yz-backup-volume.sh && sudo install -m 0644 '$DEST/systemd/yz-backup.service' '$DEST/systemd/yz-backup.timer' /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now yz-backup.timer"
fi

ssh "deploy@$HOST" "cd '$DEST' && docker compose up -d"
