#!/usr/bin/env bash
set -euo pipefail

exec /usr/local/sbin/yz-backup-volume.sh \
  "$(cd "$(dirname "$0")" && pwd)" \
  uptime-kuma \
  /var/lib/docker/volumes/ops-uptime-kuma-data/_data \
  uptime-kuma.tar.gz
