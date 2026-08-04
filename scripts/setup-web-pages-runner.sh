#!/bin/sh
set -e

# Idempotent host setup for the web-pages repo's deploy pipeline (a separate
# GitHub Actions runner from this repo's own, see README "web-pages" section).
# Safe to re-run — every step checks before changing anything. Creates:
#   - the `terraform` CLI (apt, HashiCorp's official repo)
#   - group `static_sites` + /srv/static-sites/{sites,Caddyfile}, group-writable
#     so the web-pages-bot runner can rsync content without sudo
#   - system user `web-pages-bot` (no login, own home dir for npm's cache),
#     in that group
#   - /srv/terraform-state/web-pages, owned by web-pages-bot, so terraform
#     state survives across deploy runs (the checkout workspace doesn't)
#   - /usr/local/bin/static-sites-reload.sh, a fixed no-argument reload
#     command, plus a sudoers rule scoping web-pages-bot to exactly that
#     command — never general docker access
#   - the second GitHub Actions runner (for the web-pages repo) running as
#     web-pages-bot, when WEB_PAGES_RUNNER_TOKEN is supplied; skipped with
#     instructions otherwise, since registration tokens are short-lived

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must run as root" >&2
        exit 1
    fi
}

require_root

DEPLOY_ROOT="/srv/static-sites"
RELOAD_SCRIPT="/usr/local/bin/static-sites-reload.sh"
SUDOERS_FILE="/etc/sudoers.d/web-pages-bot"
WEB_PAGES_REPO="juank1520/web-pages"
WEB_PAGES_RUNNER_HOME="/opt/actions-runner-web-pages"

echo "--- terraform ---"
if command -v terraform >/dev/null 2>&1; then
    echo "terraform already installed ($(terraform version | head -1))"
else
    if [ ! -f /etc/apt/sources.list.d/hashicorp.list ]; then
        wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
            > /etc/apt/sources.list.d/hashicorp.list
    fi
    apt-get update
    apt-get install -y terraform
    echo "Installed terraform ($(terraform version | head -1))"
fi

echo "--- static_sites group + $DEPLOY_ROOT ---"
if getent group static_sites >/dev/null; then
    echo "Group static_sites already exists"
else
    groupadd --system static_sites
    echo "Created group static_sites"
fi

mkdir -p "$DEPLOY_ROOT/sites"
touch "$DEPLOY_ROOT/Caddyfile"
chown -R root:static_sites "$DEPLOY_ROOT"
# Recursive, not just the top two levels: content synced by earlier deploy
# runs (owned by web-pages-bot) just got reclaimed by the chown above, so
# without this its previous mode (whatever `rsync -rlt` left it at, usually
# no group-write) would survive underneath — breaking the group-writable
# guarantee this block exists to provide, and with it the next deploy's
# rsync into that same tree.
find "$DEPLOY_ROOT" -type d -exec chmod 2775 {} +
find "$DEPLOY_ROOT" -type f -exec chmod 664 {} +
echo "Prepared $DEPLOY_ROOT"

echo "--- web-pages-bot user ---"
if id web-pages-bot >/dev/null 2>&1; then
    echo "User web-pages-bot already exists"
else
    useradd --system --create-home --shell /usr/sbin/nologin web-pages-bot
    echo "Created user web-pages-bot"
fi
usermod -aG static_sites web-pages-bot

# Needed even for a "system" user: the deploy job runs `npm ci` as
# web-pages-bot, and npm insists on a writable $HOME (cache, logs) or it
# fails with EACCES. --create-home only takes effect at useradd time, so
# make this idempotent step handle hosts provisioned before this fix too.
web_pages_bot_home="$(getent passwd web-pages-bot | cut -d: -f6)"
mkdir -p "$web_pages_bot_home"
chown web-pages-bot: "$web_pages_bot_home"
echo "Ensured home directory $web_pages_bot_home for web-pages-bot"

echo "--- terraform state dir ---"
# Outside the git-cleaned checkout on purpose (see web-pages's
# infra/terraform/providers.tf) — this is the only thing that lets
# terraform state survive across deploy runs on this runner.
TF_STATE_DIR="/srv/terraform-state/web-pages"
mkdir -p "$TF_STATE_DIR"
chown web-pages-bot: "$TF_STATE_DIR"
# 0700, and tighten anything already inside: terraform state holds live
# credentials (the cloudflared connector token) in cleartext, and terraform
# creates *.tfstate.backup with the default umask (0644) — so relying on the
# state files' own modes leaks the token to every local user. Locking the
# directory keeps that closed no matter what mode terraform picks next.
chmod 0700 "$TF_STATE_DIR"
find "$TF_STATE_DIR" -type f -exec chmod 0600 {} +
echo "Prepared $TF_STATE_DIR"

echo "--- reload script + sudoers ---"
cat > "$RELOAD_SCRIPT" <<'SCRIPT'
#!/bin/sh
set -e
exec docker exec static-sites caddy reload --config /etc/caddy/Caddyfile --force
SCRIPT
chown root:root "$RELOAD_SCRIPT"
chmod 0755 "$RELOAD_SCRIPT"
echo "Installed $RELOAD_SCRIPT"

tmp_sudoers="$(mktemp)"
echo "web-pages-bot ALL=(root) NOPASSWD: $RELOAD_SCRIPT" > "$tmp_sudoers"
if visudo -cf "$tmp_sudoers" >/dev/null; then
    install -m 0440 -o root -g root "$tmp_sudoers" "$SUDOERS_FILE"
    echo "Installed $SUDOERS_FILE"
else
    echo "Generated sudoers content failed validation — not installed. Review manually: $tmp_sudoers" >&2
    exit 1
fi
rm -f "$tmp_sudoers"

echo "--- web-pages actions runner ---"
# A second runner process, separate from this repo's own: GitHub can't share
# one registration across repos without a common org. Same host, same scoped
# permission model, different unix user.
#
# Registration needs a short-lived token, so it's the one part that can't
# self-heal unattended — without WEB_PAGES_RUNNER_TOKEN this block just says
# how to get one and moves on, exactly like install_runner.sh's guard. Every
# other step above already ran, so re-running with the token later is enough.
if [ -f "$WEB_PAGES_RUNNER_HOME/.runner" ]; then
    echo "Runner already registered (.runner present), not re-registering."
elif [ -z "${WEB_PAGES_RUNNER_TOKEN:-}" ]; then
    echo "Runner not registered and no WEB_PAGES_RUNNER_TOKEN given — skipping."
    echo "  On your personal computer:  ./scripts/generate-runner-token.sh juank1520/web-pages"
    echo "  Then here:                  WEB_PAGES_RUNNER_TOKEN=... sudo -E ./scripts/setup-web-pages-runner.sh"
else
    mkdir -p "$WEB_PAGES_RUNNER_HOME"

    case "$(uname -m)" in
        aarch64|arm64) runner_arch="arm64" ;;
        x86_64)        runner_arch="x64" ;;
        armv7l|armv6l) runner_arch="arm" ;;
        *) echo "Unsupported architecture $(uname -m)" >&2; exit 1 ;;
    esac

    runner_version=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | grep -m1 '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')
    if [ -z "$runner_version" ]; then
        echo "Could not determine the latest actions-runner version." >&2
        exit 1
    fi
    echo "Installing actions-runner $runner_version ($runner_arch)..."

    tmp_tarball=$(mktemp)
    curl -fsSL -o "$tmp_tarball" \
        "https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-linux-${runner_arch}-${runner_version}.tar.gz"
    tar xzf "$tmp_tarball" -C "$WEB_PAGES_RUNNER_HOME"
    rm -f "$tmp_tarball"
    chown -R web-pages-bot:web-pages-bot "$WEB_PAGES_RUNNER_HOME"

    # web-pages-bot's shell is nologin, so force one for this call only.
    echo "Registering runner against $WEB_PAGES_REPO..."
    su -s /bin/sh web-pages-bot -c "cd '$WEB_PAGES_RUNNER_HOME' && ./config.sh --unattended \
        --url 'https://github.com/$WEB_PAGES_REPO' \
        --token '$WEB_PAGES_RUNNER_TOKEN' \
        --name '$(hostname)-web-pages' \
        --labels self-hosted \
        --work _work"
fi

# Service name is scoped to this repo's slug on purpose: the host runs two
# runners, and a bare actions.runner.*.service glob matches both.
wp_service=$(basename "$(ls /etc/systemd/system/actions.runner."$(printf '%s' "$WEB_PAGES_REPO" | tr '/' '-')".*.service 2>/dev/null | head -n1)" 2>/dev/null || true)
if [ -n "$wp_service" ]; then
    if systemctl is-active --quiet "$wp_service"; then
        echo "Service $wp_service active."
    else
        echo "Service $wp_service inactive, starting..."
        systemctl start "$wp_service"
    fi
elif [ -f "$WEB_PAGES_RUNNER_HOME/.runner" ]; then
    echo "Installing runner as a systemd service running as web-pages-bot..."
    (cd "$WEB_PAGES_RUNNER_HOME" && ./svc.sh install web-pages-bot && ./svc.sh start)
fi

echo
echo "Done. web-pages-bot is NOT in the docker group — only sudo access is to $RELOAD_SCRIPT."
