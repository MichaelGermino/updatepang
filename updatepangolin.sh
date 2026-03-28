#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Pangolin Docker Updater
# =========================
# What this script does:
# 1. Reads current Pangolin version from docker-compose.yml
# 2. Pulls recent releases from GitHub
# 3. Shows the next 10 versions after the current one
# 4. Prompts user to select a target version
# 5. Rebuilds config-backup from config
# 6. Backs up docker-compose.yml to docker-compose-bkup.yml
# 7. Runs docker compose down and waits for containers to stop
# 8. Updates docker-compose.yml image tag
# 9. Runs docker compose pull
# 10. Runs docker compose up -d
#
# Requirements:
# - bash
# - curl
# - jq
# - docker compose
#
# Usage:
#   chmod +x update-pangolin.sh
#   ./update-pangolin.sh
#
# Optional:
#   COMPOSE_FILE=/path/to/docker-compose.yml ./update-pangolin.sh


#!/usr/bin/env bash
set -Eeuo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
CONFIG_DIR="${CONFIG_DIR:-config}"
BACKUP_DIR="${BACKUP_DIR:-config-backup}"
COMPOSE_BACKUP_FILE="${COMPOSE_BACKUP_FILE:-docker-compose-bkup.yml}"
IMAGE_REPO="fosrl/pangolin"
GITHUB_API_URL="https://api.github.com/repos/fosrl/pangolin/releases?per_page=30"

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

cleanup_on_error() {
  printf '\nAn error occurred. The script stopped before completion.\n' >&2
}
trap cleanup_on_error ERR

require_cmd bash
require_cmd curl
require_cmd jq
require_cmd docker
require_cmd sed
require_cmd awk
require_cmd grep
require_cmd rm
require_cmd cp
require_cmd mktemp

[[ -f "$COMPOSE_FILE" ]] || fail "Compose file not found: $COMPOSE_FILE"
[[ -d "$CONFIG_DIR" ]] || fail "Config directory not found: $CONFIG_DIR"

IMAGE_LINE="$(grep -E "^[[:space:]]*image:[[:space:]]*[\"']?${IMAGE_REPO}:[^[:space:]\"']+[\"']?" "$COMPOSE_FILE" | head -n 1 || true)"
[[ -n "$IMAGE_LINE" ]] || fail "Could not find image line for ${IMAGE_REPO} in $COMPOSE_FILE"

CURRENT_VERSION="$(printf '%s\n' "$IMAGE_LINE" | sed -E "s|^[[:space:]]*image:[[:space:]]*[\"']?${IMAGE_REPO}:([^\"'[:space:]]+)[\"']?.*$|\1|")"
[[ -n "$CURRENT_VERSION" ]] || fail "Could not parse current version from docker-compose.yml"

log "Current version in $COMPOSE_FILE: $CURRENT_VERSION"

log "Fetching release list from GitHub..."
RELEASE_JSON="$(curl -fsSL \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$GITHUB_API_URL")"

mapfile -t ALL_RELEASES < <(
  printf '%s' "$RELEASE_JSON" | jq -r '
    map(select(.draft == false and .prerelease == false))
    | .[].tag_name
  ' | sed 's/^v//' | awk 'NF'
)

[[ "${#ALL_RELEASES[@]}" -gt 0 ]] || fail "No releases returned from GitHub."

CURRENT_INDEX=-1
for i in "${!ALL_RELEASES[@]}"; do
  if [[ "${ALL_RELEASES[$i]}" == "$CURRENT_VERSION" ]]; then
    CURRENT_INDEX="$i"
    break
  fi
done

if [[ "$CURRENT_INDEX" -lt 0 ]]; then
  printf '\nCurrent version %s was not found in the fetched GitHub release list.\n' "$CURRENT_VERSION"
  printf 'Recent releases returned by GitHub:\n'
  for i in "${!ALL_RELEASES[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "${ALL_RELEASES[$i]}"
    [[ "$i" -ge 9 ]] && break
  done
  fail "Cannot determine the next versions from the current version."
fi

NEXT_VERSIONS=()
for (( i = CURRENT_INDEX - 1; i >= 0 && ${#NEXT_VERSIONS[@]} < 10; i-- )); do
  NEXT_VERSIONS+=("${ALL_RELEASES[$i]}")
done

[[ "${#NEXT_VERSIONS[@]}" -gt 0 ]] || fail "No newer versions found after $CURRENT_VERSION."

printf '\nAvailable upgrade versions after %s:\n' "$CURRENT_VERSION"
for i in "${!NEXT_VERSIONS[@]}"; do
  printf '  %2d) %s\n' "$((i + 1))" "${NEXT_VERSIONS[$i]}"
done

SELECTED_VERSION=""
while true; do
  printf '\nPick a version number (1-%d) or type the exact version: ' "${#NEXT_VERSIONS[@]}"
  read -r CHOICE

  if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    if (( CHOICE >= 1 && CHOICE <= ${#NEXT_VERSIONS[@]} )); then
      SELECTED_VERSION="${NEXT_VERSIONS[$((CHOICE - 1))]}"
      break
    fi
  else
    for v in "${NEXT_VERSIONS[@]}"; do
      if [[ "$v" == "$CHOICE" ]]; then
        SELECTED_VERSION="$v"
        break
      fi
    done
    [[ -n "$SELECTED_VERSION" ]] && break
  fi

  echo "Invalid selection. Please choose one of the listed versions."
done

if [[ "$SELECTED_VERSION" == "$CURRENT_VERSION" ]]; then
  fail "Selected version is the same as the current version."
fi

printf '\nYou selected: %s\n' "$SELECTED_VERSION"
printf 'Continue? [y/N]: '
read -r CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || fail "Cancelled by user."

log "Deleting existing backup folder: $BACKUP_DIR"
rm -rf "$BACKUP_DIR"

log "Creating fresh backup: $CONFIG_DIR -> $BACKUP_DIR"
cp -a "$CONFIG_DIR" "$BACKUP_DIR"

log "Backing up $COMPOSE_FILE to $COMPOSE_BACKUP_FILE"
cp -f "$COMPOSE_FILE" "$COMPOSE_BACKUP_FILE"

log "Running: sudo docker compose down"
sudo docker compose -f "$COMPOSE_FILE" down

log "Waiting for containers in this compose project to stop..."
for _ in {1..30}; do
  RUNNING_IDS="$(sudo docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null || true)"
  if [[ -z "$RUNNING_IDS" ]]; then
    log "All compose containers are down."
    break
  fi

  ANY_RUNNING=0
  for id in $RUNNING_IDS; do
    if sudo docker ps -q --no-trunc | grep -q "^$id$"; then
      ANY_RUNNING=1
      break
    fi
  done

  if [[ "$ANY_RUNNING" -eq 0 ]]; then
    log "All compose containers are down."
    break
  fi

  sleep 2
done

RUNNING_IDS="$(sudo docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null || true)"
if [[ -n "$RUNNING_IDS" ]]; then
  ANY_RUNNING=0
  for id in $RUNNING_IDS; do
    if sudo docker ps -q --no-trunc | grep -q "^$id$"; then
      ANY_RUNNING=1
      break
    fi
  done
  [[ "$ANY_RUNNING" -eq 0 ]] || fail "Some compose containers still appear to be running."
fi

log "Updating image version in $COMPOSE_FILE"

CURRENT_IMAGE_REGEX='^[[:space:]]*image:[[:space:]]*["'\'']?fosrl/pangolin:[^"'\''[:space:]]+["'\'']?[[:space:]]*$'

if ! grep -Eq "$CURRENT_IMAGE_REGEX" "$COMPOSE_FILE"; then
  fail "Could not find a valid Pangolin image line to update in $COMPOSE_FILE"
fi

sed -Ei \
  's|^([[:space:]]*image:[[:space:]]*["'\'']?fosrl/pangolin:)[^"'\''[:space:]]+(["'\'']?[[:space:]]*)$|\1'"$SELECTED_VERSION"'\2|' \
  "$COMPOSE_FILE"

UPDATED_LINE="$(grep -E '^[[:space:]]*image:[[:space:]]*["'\'']?fosrl/pangolin:' "$COMPOSE_FILE" | head -n 1 || true)"

[[ -n "$UPDATED_LINE" ]] || fail "Updated image line could not be found after modification."
[[ "$UPDATED_LINE" == *"fosrl/pangolin:${SELECTED_VERSION}"* ]] || fail "Compose file update verification failed. Found: $UPDATED_LINE"

log "Updated image line:"
printf '%s\n' "$UPDATED_LINE"

log "Running: sudo docker compose pull"
sudo docker compose -f "$COMPOSE_FILE" pull

log "Running: sudo docker compose up -d"
sudo docker compose -f "$COMPOSE_FILE" up -d

log "Update complete."
printf '\nOld version: %s\nNew version: %s\n' "$CURRENT_VERSION" "$SELECTED_VERSION"
printf 'Config backup folder: %s\n' "$BACKUP_DIR"
printf 'Compose backup file: %s\n' "$COMPOSE_BACKUP_FILE"
