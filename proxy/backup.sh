#!/usr/bin/env bash
set -euo pipefail

exec /usr/local/sbin/yz-backup-volume.sh \
  "$(cd "$(dirname "$0")" && pwd)" \
  traefik \
  /var/lib/docker/volumes/proxy-letsencrypt/_data \
  acme.tar.gz
