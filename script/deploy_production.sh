#!/usr/bin/env bash
set -euo pipefail

SERVER="${SERVER:-root@amituofo.com.au}"
REMOTE_DIR="${REMOTE_DIR:-/var/detail_image_generator}"
IMAGE="${IMAGE:-ghcr.io/edward0127/detail_image_generator}"
PLATFORM="${PLATFORM:-linux/amd64}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-http://127.0.0.1:3015/up}"
PUSH_GIT="${PUSH_GIT:-true}"
SKIP_REMOTE="${SKIP_REMOTE:-false}"
SSH_KEY="${SSH_KEY:-}"
AUTO_COMMIT_MESSAGE=""

usage() {
  cat <<'EOF'
Usage:
  ./script/deploy_production.sh [options]

Options:
  --auto-commit "message"        Stage all changes and create a commit before push/build.
  --no-push-git                  Skip git push.
  --skip-remote                  Build and push images, but skip SSH deploy.
  --server user@host             SSH target (default: root@amituofo.com.au).
  --remote-dir /path             Remote repo path (default: /var/detail_image_generator).
  --image ghcr.io/org/repo       Image repo (default: ghcr.io/edward0127/detail_image_generator).
  --platform linux/amd64         Buildx platform (default: linux/amd64).
  --healthcheck-url URL          Remote healthcheck URL (default: http://127.0.0.1:3015/up).
  --ssh-key /path/to/key         SSH private key path.
  -h, --help                     Show this help.

Examples:
  ./script/deploy_production.sh --auto-commit "Deploy detail image generator"
  ./script/deploy_production.sh --no-push-git --skip-remote
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-commit)
      [[ $# -lt 2 ]] && { echo "Missing value for --auto-commit" >&2; usage; exit 1; }
      AUTO_COMMIT_MESSAGE="$2"
      shift 2
      ;;
    --no-push-git)
      PUSH_GIT="false"
      shift
      ;;
    --skip-remote)
      SKIP_REMOTE="true"
      shift
      ;;
    --server)
      [[ $# -lt 2 ]] && { echo "Missing value for --server" >&2; usage; exit 1; }
      SERVER="$2"
      shift 2
      ;;
    --remote-dir)
      [[ $# -lt 2 ]] && { echo "Missing value for --remote-dir" >&2; usage; exit 1; }
      REMOTE_DIR="$2"
      shift 2
      ;;
    --image)
      [[ $# -lt 2 ]] && { echo "Missing value for --image" >&2; usage; exit 1; }
      IMAGE="$2"
      shift 2
      ;;
    --platform)
      [[ $# -lt 2 ]] && { echo "Missing value for --platform" >&2; usage; exit 1; }
      PLATFORM="$2"
      shift 2
      ;;
    --healthcheck-url)
      [[ $# -lt 2 ]] && { echo "Missing value for --healthcheck-url" >&2; usage; exit 1; }
      HEALTHCHECK_URL="$2"
      shift 2
      ;;
    --ssh-key)
      [[ $# -lt 2 ]] && { echo "Missing value for --ssh-key" >&2; usage; exit 1; }
      SSH_KEY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

for cmd in git docker ssh; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

if ! docker buildx version >/dev/null 2>&1; then
  echo "Missing required docker buildx support." >&2
  exit 1
fi

if [[ -n "$AUTO_COMMIT_MESSAGE" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Creating commit: $AUTO_COMMIT_MESSAGE"
    git add -A
    git commit -m "$AUTO_COMMIT_MESSAGE"
  else
    echo "No local changes detected, skipping auto-commit."
  fi
fi

if [[ -n "$(git status --porcelain)" ]]; then
  cat >&2 <<'EOF'
Working tree is not clean.
Commit or stash changes first, or use:
  ./script/deploy_production.sh --auto-commit "your message"
EOF
  exit 1
fi

if [[ "$PUSH_GIT" == "true" ]]; then
  echo "Pushing current branch..."
  git push
fi

SHORT_SHA="$(git rev-parse --short HEAD)"
if [[ -z "$SHORT_SHA" ]]; then
  echo "Could not resolve git short SHA." >&2
  exit 1
fi

echo "Building and pushing images:"
echo "  ${IMAGE}:${SHORT_SHA}"
echo "  ${IMAGE}:latest"
docker buildx build --platform "$PLATFORM" \
  -t "${IMAGE}:${SHORT_SHA}" \
  -t "${IMAGE}:latest" \
  --push .

if [[ "$SKIP_REMOTE" == "true" ]]; then
  echo "Skipping remote deployment (--skip-remote)."
  exit 0
fi

SSH_ARGS=()
if [[ -n "$SSH_KEY" ]]; then
  if [[ "$SSH_KEY" =~ ^[A-Za-z]:\\ ]] && command -v cygpath >/dev/null 2>&1; then
    SSH_KEY="$(cygpath -u "$SSH_KEY")"
  elif [[ "$SSH_KEY" =~ ^/[A-Za-z]/ ]] && command -v cygpath >/dev/null 2>&1; then
    SSH_KEY="$(cygpath -u "$SSH_KEY")"
  fi

  if [[ ! -f "$SSH_KEY" ]]; then
    echo "SSH key not found: $SSH_KEY" >&2
    exit 1
  fi

  SSH_ARGS+=(-i "$SSH_KEY")
fi

SSH_OPTIONS=(-o BatchMode=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no)

echo "Running remote deploy on ${SERVER}:${REMOTE_DIR}..."
REMOTE_CMD="set -euo pipefail; cd '$REMOTE_DIR'; git pull --ff-only; HEALTHCHECK_URL='$HEALTHCHECK_URL' ./script/deploy.sh deploy"
if ! ssh "${SSH_OPTIONS[@]}" "${SSH_ARGS[@]}" "$SERVER" "$REMOTE_CMD"; then
  echo "Remote deployment failed. Check SSH access and server logs." >&2
  exit 1
fi

echo "Deployment complete."
