#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
APP_SERVICE="${APP_SERVICE:-web}"
CONTAINER_NAME="${CONTAINER_NAME:-detail_image_generator}"
GIT_PULL="${GIT_PULL:-0}"
RUN_DB_PREPARE="${RUN_DB_PREPARE:-1}"
RUN_SEED="${RUN_SEED:-0}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-http://127.0.0.1:3015/up}"

usage() {
  cat <<'EOF'
Usage:
  ./script/deploy.sh deploy      # pull image, prepare DB, optional seed, restart, verify, healthcheck
  ./script/deploy.sh restart     # down+up only, then verify and healthcheck
  ./script/deploy.sh prepare     # run db:prepare only
  ./script/deploy.sh migrate     # run db:migrate only
  ./script/deploy.sh seed        # run db:seed only
  ./script/deploy.sh pull        # pull image only
  ./script/deploy.sh verify      # verify running container uses pulled image
  ./script/deploy.sh logs        # tail app logs
  ./script/deploy.sh status      # show compose status and image IDs
  ./script/deploy.sh down        # stop stack without removing volumes

Environment overrides:
  COMPOSE_FILE=docker-compose.yml
  APP_SERVICE=web
  CONTAINER_NAME=detail_image_generator
  GIT_PULL=1
  RUN_DB_PREPARE=0
  RUN_SEED=1
  HEALTHCHECK_URL=http://127.0.0.1:3015/up
EOF
}

ensure_prerequisites() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not installed." >&2
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: docker compose plugin is required." >&2
    exit 1
  fi

  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "ERROR: compose file not found: $COMPOSE_FILE" >&2
    exit 1
  fi

  if [[ ! -f ".env.prod" ]]; then
    echo "ERROR: .env.prod not found. Copy .env.prod.example and fill real production values." >&2
    exit 1
  fi
}

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

maybe_git_pull() {
  if [[ "$GIT_PULL" == "1" ]]; then
    echo "== git pull --ff-only =="
    git pull --ff-only
  fi
}

pull_image() {
  echo "== docker compose pull $APP_SERVICE =="
  compose pull "$APP_SERVICE"
}

prepare() {
  echo "== db:prepare =="
  compose run --rm --no-deps "$APP_SERVICE" bin/rails db:prepare
}

migrate() {
  echo "== db:migrate =="
  compose run --rm --no-deps "$APP_SERVICE" bin/rails db:migrate
}

seed() {
  echo "== db:seed =="
  compose run --rm --no-deps "$APP_SERVICE" bin/rails db:seed
}

restart_stack() {
  echo "== docker compose down --remove-orphans =="
  compose down --remove-orphans

  echo "== docker compose up -d $APP_SERVICE =="
  compose up -d "$APP_SERVICE"
}

service_image_ref() {
  compose config | awk -v svc="$APP_SERVICE" '
    $0 ~ "^  "svc":$" {in_svc=1; next}
    in_svc && $0 ~ "^    image:" {sub("^    image:[[:space:]]*", "", $0); print $0; exit}
    in_svc && $0 ~ "^  [A-Za-z0-9_-]+:$" {in_svc=0}
  '
}

image_id_for_ref() {
  local image_ref="$1"
  docker image inspect "$image_ref" --format '{{.Id}}'
}

container_image_id() {
  if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    docker inspect "$CONTAINER_NAME" --format '{{.Image}}'
    return 0
  fi

  local container_id
  container_id="$(compose ps -q "$APP_SERVICE" | head -n 1)"
  if [[ -z "${container_id:-}" ]]; then
    echo ""
    return 0
  fi

  docker inspect "$container_id" --format '{{.Image}}'
}

verify() {
  local image_ref
  image_ref="$(service_image_ref || true)"

  if [[ -z "${image_ref:-}" ]]; then
    echo "WARN: could not detect image reference from compose config." >&2
    return 1
  fi

  local pulled_id running_id
  pulled_id="$(image_id_for_ref "$image_ref")"
  running_id="$(container_image_id)"

  echo "== verify image =="
  echo "compose image ref: $image_ref"
  echo "pulled image id : $pulled_id"
  echo "running image id: $running_id"

  if [[ -z "${running_id:-}" ]]; then
    echo "ERROR: app container is not running." >&2
    return 1
  fi

  if [[ "$pulled_id" != "$running_id" ]]; then
    echo "ERROR: running container is not using the latest pulled image." >&2
    echo "Tip: run ./script/deploy.sh restart" >&2
    return 1
  fi

  echo "OK: running container matches pulled image."
}

healthcheck() {
  if [[ -z "${HEALTHCHECK_URL:-}" ]]; then
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "WARN: curl not installed, skipping healthcheck." >&2
    return 0
  fi

  echo "== healthcheck =="
  echo "URL: $HEALTHCHECK_URL"

  local max_attempts=30
  local sleep_seconds=2
  local attempt

  for attempt in $(seq 1 "$max_attempts"); do
    if curl -fsS -I "$HEALTHCHECK_URL" >/dev/null || curl -fsS "$HEALTHCHECK_URL" >/dev/null; then
      echo "OK: healthcheck passed after $attempt attempt(s)."
      return 0
    fi

    if [[ "$attempt" -lt "$max_attempts" ]]; then
      echo "Waiting for healthcheck attempt $((attempt + 1))/$max_attempts..."
      sleep "$sleep_seconds"
    fi
  done

  echo "ERROR: healthcheck failed after $max_attempts attempts." >&2
  return 1
}

status() {
  compose ps
  verify || true
}

command="${1:-deploy}"
if [[ "$command" == "-h" || "$command" == "--help" || "$command" == "help" ]]; then
  usage
  exit 0
fi

ensure_prerequisites

case "$command" in
  deploy)
    maybe_git_pull
    pull_image
    if [[ "$RUN_DB_PREPARE" == "1" ]]; then
      prepare
    fi
    if [[ "$RUN_SEED" == "1" ]]; then
      seed
    fi
    restart_stack
    verify
    healthcheck
    ;;
  restart)
    restart_stack
    verify
    healthcheck
    ;;
  prepare)
    prepare
    ;;
  migrate)
    migrate
    ;;
  seed)
    seed
    ;;
  pull)
    pull_image
    ;;
  verify)
    verify
    ;;
  logs)
    compose logs -f --tail=200 "$APP_SERVICE"
    ;;
  status)
    status
    ;;
  down)
    compose down --remove-orphans
    ;;
  *)
    echo "Unknown command: $command" >&2
    usage
    exit 1
    ;;
esac
