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
    printf '%s ALL=(root) NOPASSWD: %s\n' "$RUNNER_USER" "$HA_SYNC_SCRIPT"
} > "$SUDOERS_TMP"
if sudo visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    sudo install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
else
    echo "Error: generated sudoers rule failed validation, aborting."
    rm -f "$SUDOERS_TMP"
    exit 1
fi
rm -f "$SUDOERS_TMP"
