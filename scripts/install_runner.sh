#!/bin/sh
set -e

REPO="juank1520/home-infra"
REPO_DIR="${HOME}/home-infra"
RUNNER_USER="deploy-bot"
RUNNER_HOME="/opt/actions-runner"
DEPLOY_SCRIPT="/usr/local/bin/home-infra-deploy.sh"
SUDOERS_FILE="/etc/sudoers.d/deploy-bot"

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

echo "Installing fixed deploy script at $DEPLOY_SCRIPT (root-owned, not writable by $RUNNER_USER)..."
DEPLOY_SCRIPT_TMP=$(mktemp)
cat > "$DEPLOY_SCRIPT_TMP" << EOF
#!/bin/sh
set -e
REPO_DIR="$REPO_DIR"
git -C "\$REPO_DIR" fetch origin main
git -C "\$REPO_DIR" reset --hard origin/main
systemctl restart stacks.target
EOF
sudo install -m 0755 -o root -g root "$DEPLOY_SCRIPT_TMP" "$DEPLOY_SCRIPT"
rm -f "$DEPLOY_SCRIPT_TMP"

echo "Installing scoped sudoers rule for $RUNNER_USER..."
SUDOERS_TMP=$(mktemp)
printf '%s ALL=(root) NOPASSWD: %s\n' "$RUNNER_USER" "$DEPLOY_SCRIPT" > "$SUDOERS_TMP"
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
