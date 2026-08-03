#!/bin/sh
set -e

# Idempotent host setup for the web-pages repo's deploy pipeline (a separate
# GitHub Actions runner from this repo's own, see README "web-pages" section).
# Safe to re-run — every step checks before changing anything. Creates:
#   - the `terraform` CLI (apt, HashiCorp's official repo)
#   - group `static_sites` + /srv/static-sites/{sites,Caddyfile}, group-writable
#     so the web-pages-bot runner can rsync content without sudo
#   - system user `web-pages-bot` (no login, no home), in that group
#   - /usr/local/bin/static-sites-reload.sh, a fixed no-argument reload
#     command, plus a sudoers rule scoping web-pages-bot to exactly that
#     command — never general docker access

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
chmod 2775 "$DEPLOY_ROOT" "$DEPLOY_ROOT/sites"
chmod 664 "$DEPLOY_ROOT/Caddyfile"
echo "Prepared $DEPLOY_ROOT"

echo "--- web-pages-bot user ---"
if id web-pages-bot >/dev/null 2>&1; then
    echo "User web-pages-bot already exists"
else
    useradd --system --no-create-home --shell /usr/sbin/nologin web-pages-bot
    echo "Created user web-pages-bot"
fi
usermod -aG static_sites web-pages-bot

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

echo
echo "Done. web-pages-bot is NOT in the docker group — only sudo access is to $RELOAD_SCRIPT."
echo "Next (one-time, if not done yet): register the web-pages GitHub Actions runner to run as web-pages-bot."
