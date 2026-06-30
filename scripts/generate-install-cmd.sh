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

printf "2. Pega el token generado aqui: "
read -r GITHUB_PAT

if [ -z "$GITHUB_PAT" ]; then
    echo "Error: no se ingreso ningun token."
    exit 1
fi

echo ""
echo "Copia y ejecuta este comando en tu Raspberry Pi:"
echo ""
echo "GITHUB_PAT=$GITHUB_PAT bash -c \"\$(curl -sSL \\"
echo "  -H 'Authorization: token $GITHUB_PAT' \\"
echo "  -H 'Accept: application/vnd.github.v3.raw' \\"
echo "  '$BOOTSTRAP_URL')\""
echo ""
