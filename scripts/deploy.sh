#!/usr/bin/env bash
# Deploy one service on the VM:  scripts/deploy.sh <portfolio|expense|caddy>
#   1. git pull infra + the service's source checkout (fast-forward only)
#   2. tag the running image as :prev, build, `up -d` just that service
#   3. wait for the container to be healthy; if not, re-tag :prev and restart it (rollback)
# Also usable as an SSH forced command (authorized_keys `command="... --from-ssh"`):
# the requested service is then read from SSH_ORIGINAL_COMMAND and validated.
# Note: a rollback restores the image only. A DB migration the new version already ran
# (alembic upgrade on start) is NOT reverted.
set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/srv/infra}"
SRC_ROOT="${SRC_ROOT:-/srv/src}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"

# service -> "<compose service>:<source dir name or ->"   (part 2b: add taskboard here)
svc_lookup() {
  case "$1" in
    portfolio) echo "portfolio-api:portfolio" ;;
    expense)   echo "expense-api:expense" ;;
    caddy)     echo "caddy:-" ;;
    *) return 1 ;;
  esac
}

die() { echo "deploy: $*" >&2; exit 1; }

pull() { # dir
  local dir="$1"
  echo "--> git pull $dir ($(git -C "$dir" rev-parse --abbrev-ref HEAD))"
  git -C "$dir" pull --ff-only --quiet
  git -C "$dir" log -1 --format='    %h %s'
}

container_health() { # compose service
  local id
  id=$(docker compose ps -q "$1")
  [ -n "$id" ] || { echo missing; return; }
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id"
}

wait_healthy() { # compose service
  local svc="$1" waited=0 status
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    status=$(container_health "$svc")
    case "$status" in
      healthy) echo "--> $svc healthy after ${waited}s"; return 0 ;;
      unhealthy|exited|dead|missing) echo "--> $svc is $status"; return 1 ;;
    esac
    sleep 5; waited=$((waited + 5))
  done
  echo "--> $svc not healthy after ${HEALTH_TIMEOUT}s (last: $status)"; return 1
}

main() {
  local name="${1:-}"
  if [ "$name" = "--from-ssh" ]; then
    # shellcheck disable=SC2086
    set -- ${SSH_ORIGINAL_COMMAND:-}
    [ "${1:-}" = "deploy" ] && shift
    name="${1:-}"
  fi
  [[ "$name" =~ ^[a-z0-9-]+$ ]] || die "usage: deploy.sh <portfolio|expense|caddy>"
  local entry svc src
  entry=$(svc_lookup "$name") || die "unknown service '$name'"
  svc="${entry%%:*}"; src="${entry#*:}"

  cd "$INFRA_DIR"
  if command -v flock >/dev/null; then   # util-linux; always present on Ubuntu
    exec 9>/tmp/infra-deploy.lock
    flock -w 600 9 || die "another deploy is running"
  fi

  pull "$INFRA_DIR"
  [ "$src" = "-" ] || pull "$SRC_ROOT/$src"

  local image prev_tagged=0
  image=$(docker compose config --images "$svc" | head -1)
  if docker image inspect "$image" >/dev/null 2>&1; then
    docker image tag "$image" "${image%:*}:prev"; prev_tagged=1
  fi

  echo "--> build $svc"
  docker compose build --pull "$svc"
  echo "--> up $svc"
  docker compose up -d --no-deps "$svc"

  if [ "$svc" = "caddy" ]; then
    # Picks up Caddyfile/routes edits even when the container wasn't recreated.
    local cf
    cf=$(sed -n 's/^CADDYFILE=//p' .env 2>/dev/null | tail -1)
    docker compose exec -T caddy caddy reload --config "/etc/caddy/${cf:-Caddyfile}" --adapter caddyfile
  fi

  if wait_healthy "$svc"; then
    docker image prune -f >/dev/null
    docker compose ps "$svc"
    echo "deploy: $name OK"
    return 0
  fi

  docker compose logs --tail 40 "$svc" || true
  if [ "$prev_tagged" -eq 1 ]; then
    echo "--> ROLLBACK $svc to previous image"
    docker image tag "${image%:*}:prev" "$image"
    docker compose up -d --no-deps --force-recreate "$svc"
    wait_healthy "$svc" || echo "deploy: rollback is ALSO unhealthy, investigate now" >&2
  fi
  docker compose ps "$svc"
  die "$name deploy FAILED (rolled back: $prev_tagged)"
}

# Everything runs inside main(), which bash parses fully before running, so `git pull`
# replacing this file mid-run is safe.
main "$@"
exit
