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
