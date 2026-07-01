#!/bin/sh
set -e

REPO="juank1520/home-infra"

if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI no esta instalado. https://cli.github.com/"
    exit 1
fi

echo ""
echo "Solicitando un token de registro de runner para $REPO (expira en 1 hora)..."
RUNNER_TOKEN=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)

if [ -z "$RUNNER_TOKEN" ]; then
    echo "Error: no se pudo obtener el token. Verifica que 'gh' este autenticado con permisos de admin sobre el repo."
    exit 1
fi

echo ""
echo "Copia y ejecuta este comando en tu Raspberry Pi (dentro de ~/home-infra):"
echo ""
echo "RUNNER_TOKEN=$RUNNER_TOKEN ./scripts/install_runner.sh"
echo ""
