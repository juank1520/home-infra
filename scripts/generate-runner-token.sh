#!/bin/sh
set -e

# Mints a short-lived (1 hour) runner registration token. Run on your personal
# computer, where gh is authenticated — the server never holds a GitHub PAT.
#
# Usage: scripts/generate-runner-token.sh [owner/repo]
#   default            juank1520/home-infra  -> install_runner.sh
#   juank1520/web-pages                      -> setup-web-pages-runner.sh
# The host runs one runner per repo (GitHub can't share a registration across
# repos without a common org), so which repo you pass decides which runner —
# and therefore which script consumes the token — you're setting up.

REPO="${1:-juank1520/home-infra}"

if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI no esta instalado. https://cli.github.com/" >&2
    exit 1
fi

echo ""
echo "Solicitando un token de registro de runner para $REPO (expira en 1 hora)..."
RUNNER_TOKEN=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)

if [ -z "$RUNNER_TOKEN" ]; then
    echo "Error: no se pudo obtener el token. Verifica que 'gh' este autenticado con permisos de admin sobre el repo." >&2
    exit 1
fi

echo ""
echo "Copia y ejecuta este comando en el home server (dentro de ~/home-infra):"
echo ""
case "$REPO" in
    */web-pages)
        echo "  WEB_PAGES_RUNNER_TOKEN=$RUNNER_TOKEN sudo -E ./scripts/setup-web-pages-runner.sh"
        ;;
    *)
        echo "  RUNNER_TOKEN=$RUNNER_TOKEN ./scripts/install_runner.sh"
        ;;
esac
echo ""
