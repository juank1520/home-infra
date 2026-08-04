# Renders the runner helper templates (scripts/runner/templates/*.sh.template)
# and installs each as a fixed, root-owned, no-argument script under
# /usr/local/bin. Fixed bare script paths are what let the sudoers rules below
# stay tight — deploy-bot can't widen or re-point what actually runs.
#
# Two token styles, on purpose:
#   @@NAME@@  install-time — substituted here, now, from the constants above.
#   __NAME__  deploy-time  — LEFT UNTOUCHED; the sync-units helper renders these
#             later against docker/**/*.template. sync-units even carries a
#             literal __REPO_DIR__ (to render docker-compose@.service), which is
#             why its install-time value uses @@REPO_DIR@@ instead of colliding.
#
# home-infra-sync-units.sh.template additionally carries two @@COMMON_...@@
# markers (@@COMMON_UNIT_RENDER@@, @@COMMON_CONFIG_RENDER@@) that aren't sed
# substitutions — see the splice step below, right before that template is
# installed.

# Kept as a separate, fixed, no-argument script (rather than inlining the git
# commands in sudoers) because the repo URL contains ':' — a sudoers grammar
# special character that would otherwise need fragile escaping there.
# Prints the list of files changed by this fetch, so the deploy script can
# tell whether anything outside its own reach (scripts/*.sh, init.sh) needs a
# manual re-run.
echo "Installing fixed fetch script at $FETCH_SCRIPT (root-owned, not writable by $RUNNER_USER)..."
render_and_install home-infra-fetch.sh.template "$FETCH_SCRIPT" \
    "s#@@REPO_DIR@@#${REPO_DIR}#g; s#@@REPO_URL@@#https://github.com/${REPO}.git#g"

# Regenerates the docker-compose@.service unit from the repo's template and
# enables a unit for every directory under docker/ — so editing an existing
# stack or adding a brand new one applies automatically. Deliberately does
# NOT touch anything outside systemd units for docker-compose@* (no SSH,
# firewall, users, or sudoers) — that's the line we chose not to cross.
# Only @@REPO_DIR@@ is substituted here: the __SERVER_IP__ / __BASE_DOMAIN__ /
# __HA_*__ / __REPO_DIR__ tokens inside are rendered at DEPLOY time by this
# script itself against docker/**/*.template, so they must pass through untouched.
echo "Installing fixed unit-sync script at $SYNC_UNITS_SCRIPT (root-owned, not writable by $RUNNER_USER)..."
# This template shares its systemd-unit-render and per-service config-render
# blocks with scripts/docker_services.sh (the interactive bootstrap script) —
# kept in one place under scripts/lib/ so the two never drift. They're
# SPLICED IN HERE, now, at install time (not `source`d by the installed
# script at deploy time) so the file that ends up at $SYNC_UNITS_SCRIPT stays
# a flat, self-contained, root-owned script with no runtime dependency on the
# (mutable) repo clone — same invariant as every other line render_and_install
# produces. A plain `git push` editing scripts/lib/common-*.sh can't change
# what deploy-bot triggers as root until a human re-runs install_runner.sh.
SYNC_UNITS_TMP=$(mktemp)
awk -v unit_frag="${REPO_DIR}/scripts/lib/common-unit-render.sh" \
    -v config_frag="${REPO_DIR}/scripts/lib/common-config-render.sh" '
    /@@COMMON_UNIT_RENDER@@/   { while ((getline line < unit_frag)   > 0) print line; close(unit_frag);   next }
    /@@COMMON_CONFIG_RENDER@@/ { while ((getline line < config_frag) > 0) print line; close(config_frag); next }
    { print }
' "$TEMPLATES_DIR/home-infra-sync-units.sh.template" \
    | sed "s#@@REPO_DIR@@#${REPO_DIR}#g" > "$SYNC_UNITS_TMP"
sudo install -m 0755 -o root -g root "$SYNC_UNITS_TMP" "$SYNC_UNITS_SCRIPT"
rm -f "$SYNC_UNITS_TMP"

# Writes the values GHA secrets injected into deploy-bot's own environment
# (see .github/workflows/deploy.yml) into the repo's .env, which
# docker-compose@.service always passes to `docker compose --env-file`. Runs
# as $ADMIN_USER (not root) since that's who owns the repo clone; only takes
# env vars, no arguments, so sudoers doesn't need to escape or widen anything.
# __ENV_VARS__ becomes the space-separated list derived from .env.example.
echo "Installing fixed env-writer script at $WRITE_ENV_SCRIPT (root-owned, not writable by $RUNNER_USER)..."
render_and_install home-infra-write-env.sh.template "$WRITE_ENV_SCRIPT" \
    "s#@@REPO_DIR@@#${REPO_DIR}#g; s#@@ENV_VARS@@#${ENV_VARS}#g"

# $RUNNER_USER has no group in common with $ADMIN_USER, so it can't read
# notify_deploy.py under $REPO_DIR (owned by $ADMIN_USER). A root-owned,
# world-readable COPY at a fixed path solves that without loosening anything
# under $REPO_DIR (which would also affect acme.json/.env) — and, unlike
# exec'ing the repo path, it holds the same invariant as every other helper
# here: a plain `git push` can't change what this actually runs.
# Sending mail needs no privilege, so the wrapper is invoked directly by
# deploy-bot (see .github/workflows/deploy.yml) with no sudoers rule at all.
echo "Installing notify python at $NOTIFY_PY (root-owned, not writable by $RUNNER_USER)..."
sudo install -m 0644 -o root -g root "$REPO_DIR/scripts/notify_deploy.py" "$NOTIFY_PY"

echo "Installing fixed notify script at $NOTIFY_SCRIPT (root-owned, not writable by $RUNNER_USER)..."
render_and_install home-infra-notify.sh.template "$NOTIFY_SCRIPT" \
    "s#@@NOTIFY_PY@@#${NOTIFY_PY}#g"

echo "Installing fixed deploy script at $DEPLOY_SCRIPT (root-owned, not writable by $RUNNER_USER)..."
render_and_install home-infra-deploy.sh.template "$DEPLOY_SCRIPT" \
    "s#@@ADMIN_USER@@#${ADMIN_USER}#g; s#@@FETCH_SCRIPT@@#${FETCH_SCRIPT}#g; s#@@WRITE_ENV_SCRIPT@@#${WRITE_ENV_SCRIPT}#g; s#@@SYNC_UNITS_SCRIPT@@#${SYNC_UNITS_SCRIPT}#g; s#@@ENV_VARS_CSV@@#${ENV_VARS_CSV}#g"

# Pulls Home Assistant's packages/ from the private repo and reloads HA. Runs
# as root (scoped sudoers below) because it needs to write into the config
# bind-mount and drive docker. Triggered by deploy-ha.yml, which the private
# repo fans in via repository_dispatch. Baked-in constants only, no arguments.
echo "Installing fixed HA-sync script at $HA_SYNC_SCRIPT (root-owned, not writable by $RUNNER_USER)..."
render_and_install home-infra-ha-sync.sh.template "$HA_SYNC_SCRIPT" \
    "s#@@REPO_DIR@@#${REPO_DIR}#g; s#@@HA_PRIVATE_DIR@@#${HA_PRIVATE_DIR}#g; s#@@HA_PRIVATE_REPO@@#${HA_PRIVATE_REPO}#g; s#@@HA_DEPLOY_KEY@@#${HA_DEPLOY_KEY}#g"
