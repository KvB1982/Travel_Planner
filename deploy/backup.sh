#!/usr/bin/env bash
# Daily dump of the travel planner database, kept for 14 days.
# Runs as the normal user (member of the docker group), for example from cron:
#   15 3 * * * /srv/reisen/app/deploy/backup.sh >> /srv/reisen/backups/backup.log 2>&1
# With /srv/reisen/backups/offsite.conf present the dumps are also copied off the machine, for example to a
# Hetzner Storage Box. That file is not part of the repository and holds no password, only:
#   OFFSITE_TARGET="u123456-sub1@u123456-sub1.your-storagebox.de:reisen/"
#   OFFSITE_PORT=23
#   OFFSITE_KEY=/home/kristian/.ssh/storagebox_ed25519
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/srv/reisen/backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"

umask 077
mkdir -p "$BACKUP_DIR"
target="$BACKUP_DIR/reisen-$(date +%Y%m%d-%H%M%S).sql.gz"

cd "$APP_DIR"
# The database's own credentials are used inside the container; nothing secret is passed on the command line.
docker compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner' | gzip > "$target.tmp"

# An empty or broken dump must not replace a good one silently.
if ! gzip -t "$target.tmp" || [[ $(stat -c %s "$target.tmp") -lt 1000 ]]; then
  rm -f "$target.tmp"
  echo "$(date -Is) backup FAILED" >&2
  exit 1
fi
mv "$target.tmp" "$target"

# Uploaded documents live in a volume of the API container. A copy of them goes next to the dumps,
# as a folder that mirrors the volume: what was deleted in the app goes from here, too.
FILES_COPY="$BACKUP_DIR/files"
mkdir -p "$FILES_COPY"
if docker compose exec -T api sh -c 'tar -C /data/files -cf - .' > "$BACKUP_DIR/files.tar.tmp" 2>/dev/null && tar -tf "$BACKUP_DIR/files.tar.tmp" >/dev/null 2>&1; then
  rm -rf "$FILES_COPY.new" && mkdir -p "$FILES_COPY.new"
  tar -C "$FILES_COPY.new" -xf "$BACKUP_DIR/files.tar.tmp"
  rm -rf "$FILES_COPY" && mv "$FILES_COPY.new" "$FILES_COPY"
  echo "$(date -Is) files ok: $(find "$FILES_COPY" -type f | wc -l) documents"
else
  echo "$(date -Is) files FAILED: documents were not copied" >&2
fi
rm -f "$BACKUP_DIR/files.tar.tmp"
find "$BACKUP_DIR" -name 'reisen-*.sql.gz' -mtime +"$KEEP_DAYS" -delete
echo "$(date -Is) backup ok: $(basename "$target") ($(stat -c %s "$target") bytes)"

# A copy off the machine, so that losing the VM or its disk does not lose the data.
OFFSITE_CONF="${OFFSITE_CONF:-$BACKUP_DIR/offsite.conf}"
if [[ -f "$OFFSITE_CONF" ]]; then
  # shellcheck disable=SC1090
  source "$OFFSITE_CONF"
  ssh_opts=(-p "${OFFSITE_PORT:-23}" -i "$OFFSITE_KEY" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)
  if command -v rsync >/dev/null 2>&1; then
    # The remote folder mirrors the local one, so the same 14 days are kept there.
    if rsync -a --delete --include 'reisen-*.sql.gz' --include 'files/***' --exclude '*' -e "ssh ${ssh_opts[*]}" "$BACKUP_DIR/" "$OFFSITE_TARGET"; then
      echo "$(date -Is) offsite ok: mirrored to ${OFFSITE_TARGET%%:*}"
    else
      echo "$(date -Is) offsite FAILED (rsync)" >&2
      exit 2
    fi
  elif scp -q -P "${OFFSITE_PORT:-23}" -i "$OFFSITE_KEY" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new "$target" "$OFFSITE_TARGET"; then
    echo "$(date -Is) offsite ok: $(basename "$target") copied to ${OFFSITE_TARGET%%:*} (no rsync, old copies are not removed there)"
  else
    echo "$(date -Is) offsite FAILED (scp)" >&2
    exit 2
  fi
fi
