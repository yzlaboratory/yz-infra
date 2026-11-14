#!/usr/bin/env bash
# Copy the proxy or ops stack to the server and start it.
#
# Usage:
#   scripts/sync-stack.sh <tailscale-ip-or-host> [proxy|ops]
#
# The remote directory must already contain a .env for proxy. Create it once:
#   ssh deploy@<host> 'cd /srv/proxy && cp .env.example .env && nano .env'
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

ssh "deploy@$HOST" "cd '$DEST' && docker compose up -d"
