# Shared by scripts/docker_services.sh (bootstrap, sourced directly) and
# scripts/runner/templates/home-infra-sync-units.sh.template (auto-deploy,
# spliced in verbatim by scripts/runner/lib/install-helpers.sh when
# install_runner.sh renders it — not sourced at deploy time, so the installed
# root-owned script stays a static, self-contained file with no runtime
# dependency on the repo clone). Expects $REPO_DIR and $SUDO_PREFIX to already
# be set by the caller ("sudo " for the interactive bootstrap, "" here since
# the rendered script already runs as root), and $ENV_FILE already sourced
# (SERVER_IP, BASE_DOMAIN, HA_LATITUDE/LONGITUDE/ELEVATION,
# CLOUDFLARE_TUNNEL_TOKEN, ALEXA_CLIENT_ID/SECRET).

# NOTE: uses `if` (not `[ -d ] && rm`) on purpose — under `set -e`, the
# `&&` form returns non-zero when the path is NOT a directory (the normal
# case), which would abort the whole script on the first call.
ensure_file() {
  if [ -d "$1" ]; then
    rm -rf "$1"
  fi
}

# Render pi-hole's dnsmasq host-record with the real LAN IP — this file is
# bind-mounted as-is into the pihole container, so it can't go through
# docker compose's ${SERVER_IP} interpolation like the compose files do.
ensure_file "${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf"
if [ -n "$SERVER_IP" ] && [ -n "$BASE_DOMAIN" ]; then
  sed "s#__SERVER_IP__#${SERVER_IP}#g; s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" \
    "${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf.template" \
    > "${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf"
fi

# Same reasoning for Traefik's static config — it's bind-mounted as-is, so
# the wildcard domain has to be rendered in rather than interpolated.
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

# Render Home Assistant's secrets.yaml from .env — HA reads secrets.yaml (via
# !secret), not compose ${VAR} interpolation, so it needs the same sed pass.
ensure_file "${REPO_DIR}/docker/home-assistant/config/secrets.yaml"
if [ -n "$HA_LATITUDE" ] && [ -n "$HA_LONGITUDE" ]; then
  sed "s#__HA_LATITUDE__#${HA_LATITUDE}#g; s#__HA_LONGITUDE__#${HA_LONGITUDE}#g; s#__HA_ELEVATION__#${HA_ELEVATION}#g; s#__ALEXA_CLIENT_ID__#${ALEXA_CLIENT_ID}#g; s#__ALEXA_CLIENT_SECRET__#${ALEXA_CLIENT_SECRET}#g" \
    "${REPO_DIR}/docker/home-assistant/config/secrets.yaml.template" \
    > "${REPO_DIR}/docker/home-assistant/config/secrets.yaml"

  # Alexa Smart Home proactive reporting is optional. If unset, drop those
  # two keys instead of leaving the literal placeholder as client_id/secret
  # — that would make HA fail with a confusing auth error at report time
  # instead of simply not attempting proactive reporting.
  if [ -z "$ALEXA_CLIENT_ID" ] || [ -z "$ALEXA_CLIENT_SECRET" ]; then
    echo "ALEXA_CLIENT_ID/ALEXA_CLIENT_SECRET not set, omitting Alexa Smart Home secrets from secrets.yaml"
    grep -v -e '^alexa_client_id:' -e '^alexa_client_secret:' \
      "${REPO_DIR}/docker/home-assistant/config/secrets.yaml" \
      > "${REPO_DIR}/docker/home-assistant/config/secrets.yaml.tmp"
    mv "${REPO_DIR}/docker/home-assistant/config/secrets.yaml.tmp" "${REPO_DIR}/docker/home-assistant/config/secrets.yaml"
  fi
fi

# Install/upgrade HACS (Home Assistant Community Store), pinned by version.
# Fetched from the upstream GitHub release into custom_components/ — vendored
# code, not hand-written config, so (like packages/) it's never committed to
# git; docker/home-assistant/config/* is already blanket-ignored. Idempotent
# via a version marker file; only restarts HA if the version actually changed
# (a bind-mounted file change alone doesn't make docker compose reload it).
HACS_VERSION="2.0.5"
HACS_DIR="${REPO_DIR}/docker/home-assistant/config/custom_components/hacs"
HACS_VERSION_FILE="${HACS_DIR}/.hacs_version"
if [ ! -f "$HACS_VERSION_FILE" ] || [ "$(cat "$HACS_VERSION_FILE")" != "$HACS_VERSION" ]; then
  echo "Installing HACS ${HACS_VERSION}..."
  command -v unzip >/dev/null 2>&1 || ${SUDO_PREFIX}apt-get install -y unzip
  HACS_TMP=$(mktemp -d)
  curl -fsSL -o "${HACS_TMP}/hacs.zip" \
    "https://github.com/hacs/integration/releases/download/${HACS_VERSION}/hacs.zip"
  rm -rf "$HACS_DIR"
  mkdir -p "$HACS_DIR"
  unzip -q "${HACS_TMP}/hacs.zip" -d "$HACS_DIR"
  echo "$HACS_VERSION" > "$HACS_VERSION_FILE"
  rm -rf "$HACS_TMP"
  ${SUDO_PREFIX}docker restart home-assistant 2>/dev/null || true
fi

# Cloudflare Tunnel (public access to home-assistant for the Alexa Smart Home
# skill). config.yml is bind-mounted as-is, so the public hostname has to be
# rendered in. Auth is the tunnel token (CLOUDFLARE_TUNNEL_TOKEN, passed as
# the TUNNEL_TOKEN env var in docker-compose.yml), not a credentials file.
ensure_file "${REPO_DIR}/docker/cloudflared/config.yml"
if [ -n "$BASE_DOMAIN" ]; then
  sed "s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" \
    "${REPO_DIR}/docker/cloudflared/config.yml.template" \
    > "${REPO_DIR}/docker/cloudflared/config.yml"
fi
