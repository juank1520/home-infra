#!/bin/sh
set -e

REPO="juank1520/home-infra"
REPO_OWNER="juank1520"
BOOTSTRAP_URL="https://api.github.com/repos/$REPO/contents/scripts/bootstrap.sh"

PAT_URL="https://github.com/settings/personal-access-tokens/new\
?name=homeserver-setup\
&description=Temporary+bootstrap+token+for+home+server\
&expires_in=1\
&target_name=$REPO_OWNER\
&contents=read\
&keys=write"

echo ""
echo "1. Abriendo GitHub para crear el PAT con permisos minimos (expira en 1 dia)..."
echo "   Selecciona el repositorio '$REPO' en la UI y haz click en 'Generate token'."
echo ""
open "$PAT_URL"

printf "2. Pega el token generado aqui (no se mostrara en pantalla): "
read -rs GITHUB_PAT
echo ""

if [ -z "$GITHUB_PAT" ]; then
    echo "Error: no se ingreso ningun token."
    exit 1
fi

RUNNER_TOKEN=""
printf "3. Configurar tambien el self-hosted runner de auto-despliegue? (y/n): "
read -r SETUP_RUNNER

if [ "$SETUP_RUNNER" = "y" ] || [ "$SETUP_RUNNER" = "Y" ]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "Error: gh CLI no esta instalado (https://cli.github.com/), no se puede generar el runner token."
        exit 1
    fi

    echo "Solicitando token de registro de runner para $REPO (expira en 1 hora)..."
    RUNNER_TOKEN=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)

    if [ -z "$RUNNER_TOKEN" ]; then
        echo "Error: no se pudo obtener el runner token. Verifica que 'gh' este autenticado con permisos de admin sobre el repo."
        exit 1
    fi
fi

# Build the install command (it necessarily contains the token) into a
# variable and copy it to the clipboard instead of printing it. This keeps the
# PAT out of the terminal scrollback, shell history and any terminal logging.
if [ -n "$RUNNER_TOKEN" ]; then
    ENV_PREFIX="GITHUB_PAT=$GITHUB_PAT RUNNER_TOKEN=$RUNNER_TOKEN"
else
    ENV_PREFIX="GITHUB_PAT=$GITHUB_PAT"
fi
INSTALL_CMD="$ENV_PREFIX bash -c \"\$(curl -sSL -H 'Authorization: token $GITHUB_PAT' -H 'Accept: application/vnd.github.v3.raw' '$BOOTSTRAP_URL')\""

echo ""
if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$INSTALL_CMD" | pbcopy
    echo "Comando de instalacion copiado al portapapeles (contiene el token)."
    echo "Pegalo y ejecutalo en tu Raspberry Pi. No se imprime aqui para no dejar"
    echo "el token en el historial ni en los logs de la terminal."
else
    echo "No se encontro 'pbcopy'. Copia manualmente el siguiente comando"
    echo "(contiene el token, evita que quede en logs):"
    echo ""
    printf '%s\n' "$INSTALL_CMD"
fi
echo ""
