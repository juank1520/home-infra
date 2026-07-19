#!/bin/sh
set -e

REPO="juank1520/home-infra"
REPO_DIR="${HOME}/home-infra"
ADMIN_USER="$(whoami)"
RUNNER_USER="deploy-bot"
RUNNER_HOME="/opt/actions-runner"
FETCH_SCRIPT="/usr/local/bin/home-infra-fetch.sh"
SYNC_UNITS_SCRIPT="/usr/local/bin/home-infra-sync-units.sh"
WRITE_ENV_SCRIPT="/usr/local/bin/home-infra-write-env.sh"
NOTIFY_SCRIPT="/usr/local/bin/home-infra-notify.sh"
DEPLOY_SCRIPT="/usr/local/bin/home-infra-deploy.sh"
SUDOERS_FILE="/etc/sudoers.d/deploy-bot"
NOTIFY_ENV_VARS="GMAIL_ADDRESS GMAIL_APP_PASSWORD DEPLOY_STATUS COMMIT_SHA COMMIT_MSG MANUAL_STEP_NEEDED"
NOTIFY_ENV_VARS_CSV=$(printf '%s' "$NOTIFY_ENV_VARS" | tr ' ' ',')

# .env.example is the single source of truth for which values flow from GHA
# secrets into .env — adding a variable there is the only file-side change
# needed; it flows automatically into the write-env script's loop and into
# the deploy script's --preserve-env list. Still needs the matching
# `secrets.NAME` line added by hand in .github/workflows/deploy.yml (GitHub
# Actions doesn't allow enumerating secrets dynamically) and the secret
# itself created in GitHub (Settings > Secrets and variables > Actions).
ENV_VAR_NAMES=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$REPO_DIR/.env.example" | sed 's/=$//')
if [ -z "$ENV_VAR_NAMES" ]; then
    echo "Error: no se encontraron variables en $REPO_DIR/.env.example"
    exit 1
fi
# paste -s joins without a trailing delimiter, unlike tr + unquoted echo
# (which depends on word-splitting to drop a trailing separator).
ENV_VARS=$(printf '%s' "$ENV_VAR_NAMES" | paste -sd' ' -)
ENV_VARS_CSV=$(printf '%s' "$ENV_VAR_NAMES" | paste -sd, -)

runner_service_name() {
    basename "$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -n1)" 2>/dev/null || true
}

# config.sh registers the runner's credentials once (.runner file) and those
# never expire; only that step needs RUNNER_TOKEN. Everything else (user,
# deploy script, sudoers, systemd service) is safe to re-check/self-heal on
# every init.sh run without a token.
if [ ! -f "$RUNNER_HOME/.runner" ] && [ -z "$RUNNER_TOKEN" ]; then
    echo "Runner no registrado y no se recibio RUNNER_TOKEN, omitiendo setup del runner."
    echo "Corre scripts/generate-runner-token.sh en tu computadora personal y vuelve a ejecutar:"
    echo "  RUNNER_TOKEN=... ./scripts/install_runner.sh"
    exit 0
fi

echo "Creating dedicated system user '$RUNNER_USER' (no login shell)..."
if id -u "$RUNNER_USER" >/dev/null 2>&1; then
    echo "User $RUNNER_USER already exists."
else
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$RUNNER_USER"
fi

# Kept as a separate, fixed, no-argument script (rather than inlining the git
# commands in sudoers) because the repo URL contains ':' — a sudoers grammar
# special character that would otherwise need fragile escaping there.
# Prints the list of files changed by this fetch, so the deploy script can
# tell whether anything outside its own reach (scripts/*.sh, init.sh) needs a
# manual re-run.
echo "Installing fixed fetch script at $FETCH_SCRIPT (root-owned, not writable by $RUNNER_USER)..."
FETCH_SCRIPT_TMP=$(mktemp)
cat > "$FETCH_SCRIPT_TMP" << EOF
#!/bin/sh
set -e
REPO_DIR="$REPO_DIR"
REPO_URL="https://github.com/$REPO.git"
OLD_SHA=\$(git -C "\$REPO_DIR" rev-parse HEAD)
# Fetches straight into origin/main's tracking ref (not just FETCH_HEAD) so a
# manual "git pull" later sees the repo as already up to date, instead of
# re-fetching what this script already applied.
git -C "\$REPO_DIR" fetch "\$REPO_URL" +main:refs/remotes/origin/main
git -C "\$REPO_DIR" reset --hard refs/remotes/origin/main
git -C "\$REPO_DIR" diff --name-only "\$OLD_SHA" HEAD
EOF
sudo install -m 0755 -o root -g root "$FETCH_SCRIPT_TMP" "$FETCH_SCRIPT"
rm -f "$FETCH_SCRIPT_TMP"

# Regenerates the docker-compose@.service unit from the repo's template and
# enables a unit for every directory under docker/ — so editing an existing
# stack or adding a brand new one applies automatically. Deliberately does
# NOT touch anything outside systemd units for docker-compose@* (no SSH,
# firewall, users, or sudoers) — that's the line we chose not to cross.
echo "Installing fixed unit-sync script at $SYNC_UNITS_SCRIPT (root-owned, not writable by $RUNNER_USER)..."
SYNC_UNITS_TMP=$(mktemp)
cat > "$SYNC_UNITS_TMP" << EOF
#!/bin/sh
set -e
REPO_DIR="$REPO_DIR"
# install (not redirection) so a stale symlink at the destination gets
# replaced instead of written through — a plain \`>\` follows existing
# symlinks and would silently overwrite whatever they point to.
RENDERED_UNIT_TMP=\$(mktemp)
sed "s#__REPO_DIR__#\${REPO_DIR}#g" "\${REPO_DIR}/system/docker-compose@.service" > "\$RENDERED_UNIT_TMP"
install -m 0644 -o root -g root "\$RENDERED_UNIT_TMP" /etc/systemd/system/docker-compose@.service
rm -f "\$RENDERED_UNIT_TMP"
ln -sf "\${REPO_DIR}/system/stacks.target" /etc/systemd/system/stacks.target
systemctl daemon-reload
systemctl enable stacks.target

# Source .env for SERVER_IP (used to render the dnsmasq template below).
ENV_FILE="\${REPO_DIR}/.env"
if [ -f "\$ENV_FILE" ]; then
    . "\$ENV_FILE"
fi

# Docker auto-creates a directory at a bind-mount's host path when it
# doesn't exist yet, instead of failing — if a container ever started
# before one of the individual file-mounts below existed on disk, this
# silently leaves a stray directory that then blocks rendering/touch here
# ("cannot create ...: Is a directory"). Clear it so the file wins.
# NOTE: uses \`if\` (not \`[ -d ] && rm\`) on purpose — under \`set -e\`, the
# \`&&\` form returns non-zero when the path is NOT a directory (the normal
# case), which would abort the whole script on the first call.
ensure_file() {
    if [ -d "\$1" ]; then
        rm -rf "\$1"
    fi
}

# Render pi-hole's dnsmasq host-record with the real LAN IP — this file is
# bind-mounted as-is into the pihole container, so it can't go through
# docker compose's \${SERVER_IP} interpolation like the compose files do.
ensure_file "\${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf"
if [ -n "\$SERVER_IP" ] && [ -n "\$BASE_DOMAIN" ]; then
    sed "s#__SERVER_IP__#\${SERVER_IP}#g; s#__BASE_DOMAIN__#\${BASE_DOMAIN}#g" \\
        "\${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf.template" \\
        > "\${REPO_DIR}/docker/pi-hole/etc-dnsmasq.d/99-pihole.conf"
fi

# Same reasoning for Traefik's static config — it's bind-mounted as-is, so
# the wildcard domain has to be rendered in rather than interpolated.
ensure_file "\${REPO_DIR}/docker/traefik/traefik.yml"
if [ -n "\$BASE_DOMAIN" ]; then
    sed "s#__BASE_DOMAIN__#\${BASE_DOMAIN}#g" \\
        "\${REPO_DIR}/docker/traefik/traefik.yml.template" \\
        > "\${REPO_DIR}/docker/traefik/traefik.yml"
fi

# Traefik refuses to start if acme.json is missing or has looser
# permissions than 600 (it stores the certificate's private key).
ensure_file "\${REPO_DIR}/docker/traefik/acme.json"
touch "\${REPO_DIR}/docker/traefik/acme.json"
chmod 600 "\${REPO_DIR}/docker/traefik/acme.json"

ensure_file "\${REPO_DIR}/docker/cups/config/cupsd.conf"
if [ -n "\$SERVER_IP" ]; then
    sed "s#__SERVER_IP__#\${SERVER_IP}#g" \\
        "\${REPO_DIR}/docker/cups/config/cupsd.conf.template" \\
        > "\${REPO_DIR}/docker/cups/config/cupsd.conf"
fi
ensure_file "\${REPO_DIR}/docker/cups/config/printers.conf"
touch "\${REPO_DIR}/docker/cups/config/printers.conf"
ensure_file "\${REPO_DIR}/docker/cups/config/printers.conf.O"
touch "\${REPO_DIR}/docker/cups/config/printers.conf.O"

# Render Home Assistant's secrets.yaml from .env — HA reads secrets.yaml (via
# !secret), not compose \${VAR} interpolation, so it needs the same sed pass.
ensure_file "\${REPO_DIR}/docker/home-assistant/config/secrets.yaml"
if [ -n "\$HA_LATITUDE" ] && [ -n "\$HA_LONGITUDE" ]; then
    sed "s#__HA_LATITUDE__#\${HA_LATITUDE}#g; s#__HA_LONGITUDE__#\${HA_LONGITUDE}#g; s#__HA_ELEVATION__#\${HA_ELEVATION}#g" \\
        "\${REPO_DIR}/docker/home-assistant/config/secrets.yaml.template" \\
        > "\${REPO_DIR}/docker/home-assistant/config/secrets.yaml"
fi

apply_stack() {
    dir="\$1"
    name=\$(basename "\$dir")
    systemctl enable "docker-compose@\$name" || echo "WARNING: could not enable docker-compose@\$name" >&2
    (cd "\$dir" && docker compose --env-file="\${REPO_DIR}/.env" up -d) \\
        && systemctl reset-failed "docker-compose@\$name" 2>/dev/null \\
        || echo "WARNING: could not (re)apply docker-compose@\$name" >&2
}

disable_stack() {
    dir="\$1"
    name=\$(basename "\$dir")
    systemctl disable --now "docker-compose@\$name" 2>/dev/null || true
    (cd "\$dir" && docker compose --env-file="\${REPO_DIR}/.env" down) \\
        || echo "WARNING: could not tear down docker-compose@\$name" >&2
}

# networks creates the external networks (dns_net, proxy_net,
# internal_media_net) every other stack attaches to as external: true — this
# loop runs docker compose directly instead of via systemctl (see comment
# below), so it doesn't get the ordering guarantee systemd's
# After=docker-compose@networks.service provides for a target-driven start.
# Applying networks first here, unconditionally, is what actually prevents
# the race — directory iteration order otherwise depends on glob sorting
# (alphabetical: "cups" and "jellyfin" would run before "networks").
if [ -d "\${REPO_DIR}/docker/networks" ] && [ ! -f "\${REPO_DIR}/docker/networks/.disabled" ]; then
    apply_stack "\${REPO_DIR}/docker/networks/"
fi

for dir in "\${REPO_DIR}"/docker/*/; do
    [ -d "\$dir" ] || continue
    name=\$(basename "\$dir")
    [ "\$name" = "networks" ] && continue
    if [ -f "\${dir}.disabled" ]; then
        disable_stack "\$dir"
        continue
    fi
    apply_stack "\$dir"
done
EOF
sudo install -m 0755 -o root -g root "$SYNC_UNITS_TMP" "$SYNC_UNITS_SCRIPT"
rm -f "$SYNC_UNITS_TMP"

# Writes the values GHA secrets injected into deploy-bot's own environment
# (see .github/workflows/deploy.yml) into the repo's .env, which
# docker-compose@.service always passes to `docker compose --env-file`. Runs
# as $ADMIN_USER (not root) since that's who owns the repo clone; only takes
# env vars, no arguments, so sudoers doesn't need to escape or widen anything.
# Quoted heredoc ('EOF') + sed placeholders (not \$-escaping) so the loop body
# below is never touched by this script's own shell — only __REPO_DIR__ and
# __ENV_VARS__ get substituted, both baked in as fixed values from the list
# above, not read from the environment at runtime.
echo "Installing fixed env-writer script at $WRITE_ENV_SCRIPT (root-owned, not writable by $RUNNER_USER)..."
WRITE_ENV_TMP=$(mktemp)
cat > "$WRITE_ENV_TMP" << 'EOF'
#!/bin/sh
set -e
ENV_FILE="__REPO_DIR__/.env"
ENV_TMP=$(mktemp)
for var in __ENV_VARS__; do
    eval "val=\${$var:-}"
    printf '%s=%s\n' "$var" "$val"
done > "$ENV_TMP"
chmod 600 "$ENV_TMP"
install -m 0600 "$ENV_TMP" "$ENV_FILE"
rm -f "$ENV_TMP"
EOF
sed -i "s#__REPO_DIR__#${REPO_DIR}#g; s#__ENV_VARS__#${ENV_VARS}#g" "$WRITE_ENV_TMP"
sudo install -m 0755 -o root -g root "$WRITE_ENV_TMP" "$WRITE_ENV_SCRIPT"
rm -f "$WRITE_ENV_TMP"

# $RUNNER_USER has no group in common with $ADMIN_USER, so it can't read
# notify_deploy.py directly under $REPO_DIR (owned by $ADMIN_USER) — running
# it via this fixed, root-owned wrapper sidesteps that instead of loosening
# permissions anywhere under $REPO_DIR (which would also affect acme.json/.env).
echo "Installing fixed notify script at $NOTIFY_SCRIPT (root-owned, not writable by $RUNNER_USER)..."
NOTIFY_SCRIPT_TMP=$(mktemp)
cat > "$NOTIFY_SCRIPT_TMP" << EOF
#!/bin/sh
set -e
exec python3 "$REPO_DIR/scripts/notify_deploy.py"
EOF
sudo install -m 0755 -o root -g root "$NOTIFY_SCRIPT_TMP" "$NOTIFY_SCRIPT"
rm -f "$NOTIFY_SCRIPT_TMP"

echo "Installing fixed deploy script at $DEPLOY_SCRIPT (root-owned, not writable by $RUNNER_USER)..."
DEPLOY_SCRIPT_TMP=$(mktemp)
cat > "$DEPLOY_SCRIPT_TMP" << EOF
#!/bin/sh
set -e
CHANGED=\$(sudo -u $ADMIN_USER $FETCH_SCRIPT)
echo "\$CHANGED"
sudo -u $ADMIN_USER --preserve-env=$ENV_VARS_CSV $WRITE_ENV_SCRIPT
sudo $SYNC_UNITS_SCRIPT
if echo "\$CHANGED" | grep -qE '(^|/)init\.sh\$|^scripts/.*\.sh\$'; then
    echo "MANUAL_STEP_NEEDED=1"
fi
EOF
sudo install -m 0755 -o root -g root "$DEPLOY_SCRIPT_TMP" "$DEPLOY_SCRIPT"
rm -f "$DEPLOY_SCRIPT_TMP"

# git runs as $ADMIN_USER (the existing owner of $REPO_DIR) instead of root,
# so it never touches the repo with different ownership than what already
# owns it — no "dubious ownership" exception needed anywhere. Everything that
# runs as root is a fixed, bare script path (no arguments, no wildcards), so
# sudoers needs no escaping and deploy-bot can't widen what gets executed.
echo "Installing scoped sudoers rule for $RUNNER_USER..."
SUDOERS_TMP=$(mktemp)
{
    printf '%s ALL=(%s) NOPASSWD: %s\n' "$RUNNER_USER" "$ADMIN_USER" "$FETCH_SCRIPT"
    printf '%s ALL=(%s) NOPASSWD:SETENV: %s\n' "$RUNNER_USER" "$ADMIN_USER" "$WRITE_ENV_SCRIPT"
    printf '%s ALL=(root) NOPASSWD: %s\n' "$RUNNER_USER" "$SYNC_UNITS_SCRIPT"
    printf '%s ALL=(root) NOPASSWD:SETENV: %s\n' "$RUNNER_USER" "$NOTIFY_SCRIPT"
} > "$SUDOERS_TMP"
if sudo visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    sudo install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
else
    echo "Error: generated sudoers rule failed validation, aborting."
    rm -f "$SUDOERS_TMP"
    exit 1
fi
rm -f "$SUDOERS_TMP"

sudo mkdir -p "$RUNNER_HOME"

# Workflows don't use actions/checkout (avoids third-party Action supply-chain
# risk), so the job workspace has no copy of the repo. actions-runner reads
# this .env file and injects it into every job's environment, letting the
# workflow reference the already-deployed clone via $REPO_DIR.
echo "REPO_DIR=$REPO_DIR" | sudo tee "$RUNNER_HOME/.env" >/dev/null
sudo chown "$RUNNER_USER":"$RUNNER_USER" "$RUNNER_HOME/.env"

if [ -f "$RUNNER_HOME/.runner" ]; then
    echo "Runner ya registrado (.runner presente), no se vuelve a registrar."
else
    echo "Detecting architecture..."
    case "$(uname -m)" in
        aarch64|arm64) RUNNER_ARCH="arm64" ;;
        x86_64) RUNNER_ARCH="x64" ;;
        armv7l|armv6l) RUNNER_ARCH="arm" ;;
        *) echo "Error: unsupported architecture $(uname -m)"; exit 1 ;;
    esac
    echo "Architecture: $RUNNER_ARCH"

    echo "Fetching latest actions-runner release version..."
    RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | grep -m1 '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')
    if [ -z "$RUNNER_VERSION" ]; then
        echo "Error: could not determine latest actions-runner version."
        exit 1
    fi
    echo "Latest version: $RUNNER_VERSION"

    RUNNER_TARBALL="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
    TMP_TARBALL=$(mktemp)
    curl -fsSL -o "$TMP_TARBALL" \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"
    sudo tar xzf "$TMP_TARBALL" -C "$RUNNER_HOME"
    rm -f "$TMP_TARBALL"
    sudo chown -R "$RUNNER_USER":"$RUNNER_USER" "$RUNNER_HOME"

    echo "Registering runner against $REPO (push-only workflow trigger)..."
    sudo -u "$RUNNER_USER" sh -c "cd '$RUNNER_HOME' && ./config.sh --unattended \
        --url 'https://github.com/$REPO' \
        --token '$RUNNER_TOKEN' \
        --name \"$(hostname)-deploy\" \
        --labels self-hosted,homelab \
        --work _work"
fi

SERVICE_NAME=$(runner_service_name)
if [ -n "$SERVICE_NAME" ]; then
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "Servicio $SERVICE_NAME activo."
    else
        echo "Servicio $SERVICE_NAME inactivo, iniciando..."
        sudo systemctl start "$SERVICE_NAME"
    fi
else
    echo "Installing runner as systemd service running as $RUNNER_USER..."
    cd "$RUNNER_HOME"
    sudo ./svc.sh install "$RUNNER_USER"
    sudo ./svc.sh start
fi

echo "Done. Check status with: sudo systemctl status 'actions.runner.*'"
