#!/bin/sh
set -e

echo "Validatin if socker is insalled"
if command -v docker >/dev/null 2>&1; then

  REPO_DIR="${HOME}/home-infra"
  SUDO_PREFIX="sudo "

  # Source .env for SERVER_IP (used to render the dnsmasq template below).
  ENV_FILE="${REPO_DIR}/.env"
  if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
  fi

  # Shared with scripts/runner/templates/home-infra-sync-units.sh.template
  # (spliced in there at install time, not sourced — see the comments in
  # each file under scripts/lib/ for why).
  . "${REPO_DIR}/scripts/lib/common-unit-render.sh"
  . "${REPO_DIR}/scripts/lib/common-config-render.sh"

  for dir in "${REPO_DIR}"/docker/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    if [ -f "${dir}.disabled" ]; then
      sudo systemctl disable --now "docker-compose@${name}" 2>/dev/null || true
      (cd "$dir" && sudo docker compose --env-file="${ENV_FILE}" down) || true
      continue
    fi
    sudo systemctl enable "docker-compose@${name}"
  done

  # Start all stacks.target
  sudo systemctl start stacks.target
fi
