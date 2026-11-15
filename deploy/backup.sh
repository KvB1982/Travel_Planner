#!/usr/bin/env bash
# Daily dump of the travel planner database, kept for 14 days.
# Runs as the normal user (member of the docker group), for example from cron:
#   15 3 * * * /srv/reisen/app/deploy/backup.sh >> /srv/reisen/backups/backup.log 2>&1
# The dumps stay inside the VM; copying them elsewhere is a separate step.
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
find "$BACKUP_DIR" -name 'reisen-*.sql.gz' -mtime +"$KEEP_DAYS" -delete
echo "$(date -Is) backup ok: $(basename "$target") ($(stat -c %s "$target") bytes)"
