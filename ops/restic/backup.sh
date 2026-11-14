#!/usr/bin/env bash
# Daily restic backup for the yz-infra host.
#
# Runs from systemd as root. Configuration comes from
# /etc/yz-infra/restic.env. The example targets Cloudflare R2 over the S3 API;
# B2 or SFTP work with a different RESTIC_REPOSITORY.
set -euo pipefail

ENV_FILE=${RESTIC_ENV_FILE:-/etc/yz-infra/restic.env}
[[ -r $ENV_FILE ]] || { echo "missing $ENV_FILE" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is required}"
export RESTIC_REPOSITORY RESTIC_PASSWORD
export RESTIC_CACHE_DIR=${RESTIC_CACHE_DIR:-/var/cache/restic}

HEALTHCHECK_URL=${HEALTHCHECK_URL:-}
on_exit() {
  local rc=$?
  if [[ -n $HEALTHCHECK_URL && $rc -ne 0 ]]; then
    curl -fsS -m 10 "${HEALTHCHECK_URL}/fail" >/dev/null 2>&1 || true
  fi
}
trap on_exit EXIT

# Give each app/stack a chance to produce a consistent database dump before the
# snapshot. Hooks must be executable.
shopt -s nullglob
hook_failed=0
for hook in /srv/apps/*/backup.sh /srv/proxy/backup.sh /srv/ops/backup.sh; do
  if [[ -x $hook ]]; then
    echo "running app backup hook: $hook"
    if ! "$hook"; then
      echo "WARNING: backup hook failed, continuing with the host snapshot: $hook" >&2
      hook_failed=1
    fi
  fi
done

restic backup \
  --tag yz-infra \
  --exclude-caches \
  --exclude '/etc/yz-infra/restic.env' \
  --exclude '/etc/yz-infra/bootstrap.env' \
  /srv/apps \
  /srv/proxy \
  /srv/ops \
  /etc/yz-infra

restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune

if [[ ${RESTIC_CHECK:-0} == "1" ]]; then
  restic check --read-data-subset=5%
fi

if [[ $hook_failed -ne 0 ]]; then
  echo "one or more backup hooks failed; the host snapshot was still created" >&2
  exit 1
fi

if [[ -n $HEALTHCHECK_URL ]]; then
  curl -fsS -m 10 "$HEALTHCHECK_URL" >/dev/null || true
fi
