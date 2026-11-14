#!/usr/bin/env bash
# Snapshot Traefik's certificate volume into /srv/proxy/backups so the host
# restic job picks it up. Certificates are reproducible, but re-issuing after
# repeated volume loss can hit Let's Encrypt rate limits.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p backups

VOLUME_DATA=/var/lib/docker/volumes/proxy-letsencrypt/_data
if [[ -d $VOLUME_DATA ]]; then
  tar -czf backups/acme.tar.gz -C "$VOLUME_DATA" .
fi

find backups -type f -mtime +7 -delete
