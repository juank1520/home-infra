# Shared constants and helpers for install_runner.sh.
# Sourced (not executed) so every lib/*.sh below sees these values.

REPO="juank1520/home-infra"
REPO_DIR="${HOME}/home-infra"
ADMIN_USER="$(whoami)"
RUNNER_USER="deploy-bot"
RUNNER_HOME="/opt/actions-runner"
FETCH_SCRIPT="/usr/local/bin/home-infra-fetch.sh"
SYNC_UNITS_SCRIPT="/usr/local/bin/home-infra-sync-units.sh"
WRITE_ENV_SCRIPT="/usr/local/bin/home-infra-write-env.sh"
NOTIFY_SCRIPT="/usr/local/bin/home-infra-notify.sh"
# The python the wrapper above runs, installed root-owned at a fixed path
# rather than executed straight out of $REPO_DIR — same invariant as every
# other helper: what runs here can't change until a human re-runs this
# installer, no matter what lands in the repo clone.
NOTIFY_PY="/usr/local/lib/home-infra-notify-deploy.py"
DEPLOY_SCRIPT="/usr/local/bin/home-infra-deploy.sh"
HA_SYNC_SCRIPT="/usr/local/bin/home-infra-ha-sync.sh"
SUDOERS_FILE="/etc/sudoers.d/deploy-bot"
# Home Assistant's packages/ come from a separate PRIVATE repo, pulled with a
# read-only deploy key. These constants are rendered into the HA-sync template.
HA_PRIVATE_REPO="juank1520/home-assistant-private"
HA_PRIVATE_DIR="/opt/home-assistant-private"
HA_DEPLOY_KEY="/root/.ssh/ha-private-deploy"

# The runner helper scripts (home-infra-*.sh) live as checked-in templates with
# __PLACEHOLDER__ tokens; render_and_install below renders and installs them.
TEMPLATES_DIR="$(dirname "$0")/runner/templates"

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

# render_and_install <template-basename> <dest-path> <sed-script>
# Renders a runner helper template into a root-owned, 0755 script at <dest>,
# substituting only the tokens named in <sed-script>. Kept root-owned and not
# writable by $RUNNER_USER so deploy-bot can't tamper with what it runs.
render_and_install() {
    _rai_tmp=$(mktemp)
    sed "$3" "$TEMPLATES_DIR/$1" > "$_rai_tmp"
    sudo install -m 0755 -o root -g root "$_rai_tmp" "$2"
    rm -f "$_rai_tmp"
}
