# Shared by scripts/docker_services.sh (bootstrap, sourced directly) and
# scripts/runner/templates/home-infra-sync-units.sh.template (auto-deploy,
# spliced in verbatim by scripts/runner/lib/install-helpers.sh when
# install_runner.sh renders it — not sourced at deploy time, so the installed
# root-owned script stays a static, self-contained file with no runtime
# dependency on the repo clone). Expects $REPO_DIR and $SUDO_PREFIX to already
# be set by the caller ("sudo " for the interactive bootstrap, "" here since
# the rendered script already runs as root).
RENDERED_UNIT_TMP=$(mktemp)
sed "s#__REPO_DIR__#${REPO_DIR}#g" "${REPO_DIR}/system/docker-compose@.service" > "$RENDERED_UNIT_TMP"
${SUDO_PREFIX}install -m 0644 -o root -g root "$RENDERED_UNIT_TMP" /etc/systemd/system/docker-compose@.service
rm -f "$RENDERED_UNIT_TMP"
${SUDO_PREFIX}ln -sf "${REPO_DIR}/system/stacks.target" /etc/systemd/system/stacks.target
${SUDO_PREFIX}systemctl daemon-reload
${SUDO_PREFIX}systemctl enable stacks.target
