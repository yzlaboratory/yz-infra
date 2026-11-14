#!/usr/bin/env bash
# Snapshot Uptime Kuma's data volume into /srv/ops/backups so the host restic
# job picks it up. Dozzle has no persistent state.
#
# Uptime Kuma uses SQLite, so stop it briefly for a consistent file copy.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p backups

container=$(docker compose ps -q uptime-kuma 2>/dev/null | head -n1 || true)
start_after=0
if [[ -n $container && $(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false) == "true" ]]; then
  docker compose stop uptime-kuma >/dev/null
  start_after=1
fi
cleanup() {
  if [[ $start_after -eq 1 ]]; then
    if ! docker compose start uptime-kuma >/dev/null 2>&1; then
      echo "WARNING: could not restart uptime-kuma" >&2
    fi
  fi
}
trap cleanup EXIT

VOLUME_DATA=/var/lib/docker/volumes/ops-uptime-kuma-data/_data
if [[ -d $VOLUME_DATA ]]; then
  tar -czf backups/uptime-kuma.tar.gz -C "$VOLUME_DATA" .
fi

find backups -type f -mtime +7 -delete
