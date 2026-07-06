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

  ensure_file() {
    [ -d "$1" ] && rm -rf "$1"
  }

  RENDERED_UNIT_TMP=$(mktemp)
  sed "s#__REPO_DIR__#${REPO_DIR}#g" "${REPO_DIR}/system/docker-compose@.service" > "$RENDERED_UNIT_TMP"
  sudo install -m 0644 -o root -g root "$RENDERED_UNIT_TMP" /etc/systemd/system/docker-compose@.service
  rm -f "$RENDERED_UNIT_TMP"
  sudo ln -sf ${REPO_DIR}/system/stacks.target /etc/systemd/system/stacks.target

  sudo systemctl daemon-reload

  ensure_file "${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf"
  if [ -n "$SERVER_IP" ] && [ -n "$BASE_DOMAIN" ]; then
    sed "s#__SERVER_IP__#${SERVER_IP}#g; s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" \
      "${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf.template" \
      > "${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf"
  fi

  ensure_file "${REPO_DIR}/docker/traefik/traefik.yml"
  if [ -n "$BASE_DOMAIN" ]; then
    sed "s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" \
      "${REPO_DIR}/docker/traefik/traefik.yml.template" \
      > "${REPO_DIR}/docker/traefik/traefik.yml"
  fi

  # Traefik refuses to start if acme.json is missing or has looser
  # permissions than 600 (it stores the certificate's private key).
  ensure_file "${REPO_DIR}/docker/traefik/acme.json"
  touch "${REPO_DIR}/docker/traefik/acme.json"
  chmod 600 "${REPO_DIR}/docker/traefik/acme.json"

  ensure_file "${REPO_DIR}/docker/cups/config/cupsd.conf"
  if [ -n "$SERVER_IP" ]; then
    sed "s#__SERVER_IP__#${SERVER_IP}#g" \
      "${REPO_DIR}/docker/cups/config/cupsd.conf.template" \
      > "${REPO_DIR}/docker/cups/config/cupsd.conf"
  fi
  ensure_file "${REPO_DIR}/docker/cups/config/printers.conf"
  touch "${REPO_DIR}/docker/cups/config/printers.conf"
  ensure_file "${REPO_DIR}/docker/cups/config/printers.conf.O"
  touch "${REPO_DIR}/docker/cups/config/printers.conf.O"

  # Enable stacks.target to inicilize when the system starts
  sudo systemctl enable stacks.target

  for dir in "${REPO_DIR}"/docker/*/; do
    [ -d "$dir" ] || continue
    [ -f "${dir}.disabled" ] && continue
    name=$(basename "$dir")
    sudo systemctl enable "docker-compose@${name}"
  done

  # Start all stacks.target
  sudo systemctl start stacks.target
fi
