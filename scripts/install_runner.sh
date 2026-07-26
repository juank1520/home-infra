#!/bin/sh
set -e

# Installs the self-hosted GitHub Actions runner and every fixed helper script
# the deploy workflows call. The work is split across scripts/runner/lib/*.sh,
# sourced (not executed) below so they share the constants from config.sh and
# so guard.sh's early `exit 0` can short-circuit the whole installer.
#
# Invoked by init.sh, or manually after minting a token:
#   RUNNER_TOKEN=... ./scripts/install_runner.sh
LIB_DIR="$(dirname "$0")/runner/lib"

. "$LIB_DIR/config.sh"          # constants + ENV_VARS from .env.example + helpers
. "$LIB_DIR/guard.sh"           # bail early if the runner isn't registered and no token
. "$LIB_DIR/user.sh"            # create the deploy-bot system user
. "$LIB_DIR/install-helpers.sh" # render + install /usr/local/bin/home-infra-*.sh
. "$LIB_DIR/sudoers.sh"         # scoped /etc/sudoers.d/deploy-bot
. "$LIB_DIR/runner.sh"          # download, register and start the actions-runner

echo "Done. Check status with: sudo systemctl status 'actions.runner.*'"
