#!/bin/sh
set -e

echo "Validatin if socker is insalled"
if command -v docker >/dev/null 2>&1; then

  REPO_DIR="${HOME}/home-infra"

  # Source .env for SERVER_IP (used to render the dnsmasq template below).
  ENV_FILE="${REPO_DIR}/.env"
  if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
  fi

  # Render docker-compose@.service with the real repo path (WorkingDirectory can't use $HOME).
  # Uses install (not tee/redirection) so a stale symlink at the destination
  # gets replaced instead of written through — tee/`>` follow existing
  # symlinks and would silently overwrite whatever they point to.
  RENDERED_UNIT_TMP=$(mktemp)
  sed "s#__REPO_DIR__#${REPO_DIR}#g" "${REPO_DIR}/system/docker-compose@.service" > "$RENDERED_UNIT_TMP"
  sudo install -m 0644 -o root -g root "$RENDERED_UNIT_TMP" /etc/systemd/system/docker-compose@.service
  rm -f "$RENDERED_UNIT_TMP"
  sudo ln -sf ${REPO_DIR}/system/stacks.target /etc/systemd/system/stacks.target

  sudo systemctl daemon-reload

  # Render pi-hole's dnsmasq host-record with the real LAN IP — this file is
  # bind-mounted as-is into the pihole container, so it can't go through
  # docker compose's ${SERVER_IP} interpolation like the compose files do.
  if [ -n "$SERVER_IP" ]; then
    sed "s#__SERVER_IP__#${SERVER_IP}#g" \
      "${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf.template" \
      > "${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf"
  fi

  # Enable stacks.target to inicilize when the system starts
  sudo systemctl enable stacks.target

  # Link docker services into stack.target docker-compose@DOCKER-FILE-NAME
  sudo systemctl enable docker-compose@networks
  sudo systemctl enable docker-compose@pi-hole
  sudo systemctl enable docker-compose@traefik
  sudo systemctl enable docker-compose@qbittorrent
  sudo systemctl enable docker-compose@sonarr
  sudo systemctl enable docker-compose@radarr
  sudo systemctl enable docker-compose@prowlarr
  sudo systemctl enable docker-compose@jellyfin
  sudo systemctl enable docker-compose@cups

  # Start all stacks.target
  sudo systemctl start stacks.target
fi
