# Dedicated system user the actions-runner and all deploy steps run as.
echo "Creating dedicated system user '$RUNNER_USER' (no login shell)..."
if id -u "$RUNNER_USER" >/dev/null 2>&1; then
    echo "User $RUNNER_USER already exists."
else
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$RUNNER_USER"
fi
