#!/bin/sh
# Nightly pg_dump of every database listed as BACKUP_<NAME>_URL in the environment.
#   BACKUP_EXPENSE_URL=postgresql://user:pass@expense-db:5432/db  -> /backups/expense/
# Add a DB later (e.g. taskboard): add BACKUP_TASKBOARD_URL to env/backup.env, mount
# ./backups/taskboard, and attach the backup service to taskboard's db network.
#   backup.sh         run forever, dumping daily at BACKUP_AT (HH:MM UTC, default 21:00 = 02:30 IST)
#   backup.sh once    dump everything now and exit
set -eu
KEEP_DAYS="${BACKUP_KEEP_DAYS:-7}"
AT="${BACKUP_AT:-21:00}"

dump_all() {
  rc=0
  for var in $(env | sed -n 's/^\(BACKUP_[A-Z0-9_]*_URL\)=.*/\1/p'); do
    name=$(echo "$var" | sed 's/^BACKUP_\(.*\)_URL$/\1/' | tr '[:upper:]' '[:lower:]')
    url=$(printenv "$var")
    dir="/backups/$name"
    mkdir -p "$dir"
    out="$dir/$name-$(date +%Y%m%d-%H%M%S).dump"
    if pg_dump --format=custom --no-owner --dbname="$url" --file="$out.part"; then
      mv "$out.part" "$out"
      echo "$(date -Iseconds) backup ok: $out ($(du -h "$out" | cut -f1))"
    else
      rm -f "$out.part"; echo "$(date -Iseconds) backup FAILED: $name" >&2; rc=1
    fi
    find "$dir" -name "$name-*.dump" -type f -mtime +"$((KEEP_DAYS - 1))" -delete
  done
  return $rc
}

if [ "${1:-}" = "once" ]; then dump_all; exit $?; fi

echo "backup scheduler: daily at $AT, keeping $KEEP_DAYS days"
while true; do
  now=$(date +%s)
  target=$(date -d "$(date +%Y-%m-%d) $AT" +%s 2>/dev/null || date -D '%Y-%m-%d %H:%M' -d "$(date +%Y-%m-%d) $AT" +%s)
  [ "$target" -le "$now" ] && target=$((target + 86400))
  sleep $((target - now))
  dump_all || true
done
