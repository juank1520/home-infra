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

  RENDERED_UNIT_TMP=$(mktemp)
  sed "s#__REPO_DIR__#${REPO_DIR}#g" "${REPO_DIR}/system/docker-compose@.service" > "$RENDERED_UNIT_TMP"
  sudo install -m 0644 -o root -g root "$RENDERED_UNIT_TMP" /etc/systemd/system/docker-compose@.service
  rm -f "$RENDERED_UNIT_TMP"
  sudo ln -sf ${REPO_DIR}/system/stacks.target /etc/systemd/system/stacks.target

  sudo systemctl daemon-reload

  if [ -n "$SERVER_IP" ] && [ -n "$BASE_DOMAIN" ]; then
    sed "s#__SERVER_IP__#${SERVER_IP}#g; s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" \
      "${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf.template" \
      > "${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf"
  fi

  if [ -n "$BASE_DOMAIN" ]; then
    sed "s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" \
      "${REPO_DIR}/docker/traefik/traefik.yml.template" \
      > "${REPO_DIR}/docker/traefik/traefik.yml"
  fi

  # Traefik refuses to start if acme.json is missing or has looser
  # permissions than 600 (it stores the certificate's private key).
  touch "${REPO_DIR}/docker/traefik/acme.json"
  chmod 600 "${REPO_DIR}/docker/traefik/acme.json"

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
