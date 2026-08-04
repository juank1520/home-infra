#!/bin/sh
# Populate the GitHub Actions secrets both repos' workflows depend on.
#
# Runs on your personal computer, where gh is authenticated — the server never
# holds a GitHub PAT, and secret VALUES never touch the repo or the server's
# disk except as the .env that home-infra-write-env.sh renders from them.
#
# GitHub never gives a secret's value back, so this can only ever know whether
# a secret EXISTS and when it changed. That's why "leave as is" is always the
# default: there is no way to diff what's stored against what you'd type.
#
# Usage: scripts/setup-gha-secrets.sh [--all | --missing | --review]
set -eu

HOME_INFRA_REPO="juank1520/home-infra"
WEB_PAGES_REPO="juank1520/web-pages"

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; BLUE="\033[0;34m"; DIM="\033[2m"; NC="\033[0m"

# NAME|REPO|KIND|HINT
#   KIND text   — echoed while typing (not a credential)
#   KIND secret — input hidden
#   KIND gen    — input hidden, and can be generated randomly on request
# Keep this list in sync with .env.example (home-infra's workflow derives the
# .env it writes from exactly those names) plus the two GMAIL_* the notify
# step uses directly.
manifest() {
    cat <<'EOF'
SSH_PORT|home-infra|text|Puerto SSH del server (no 22). Si no coincide con el real, harden.sh te deja fuera.
SERVER_IP|home-infra|text|IP LAN fija del server, ej. 192.168.1.45. La usan netplan, Pi-hole y los bindings de puertos.
TZ|home-infra|text|Zona horaria, ej. America/Costa_Rica
BASE_DOMAIN|home-infra|text|Dominio base de los hostnames internos y del tunnel, ej. jchomes.uk
ACME_EMAIL|home-infra|text|Email para Let's Encrypt (avisos de expiracion)
PIHOLE_WEBPASSWORD|home-infra|gen|Password del admin web de Pi-hole
CUPS_ADMIN_PASSWORD|home-infra|gen|Password del admin de CUPS
CF_DNS_API_TOKEN|home-infra|secret|Token Cloudflare para el reto DNS-01 de Traefik (Zone:DNS:Edit)
CLOUDFLARE_TUNNEL_TOKEN|home-infra|secret|Token del conector del tunnel personal (Zero Trust > Tunnels > el tunnel > Install connector)
WEB_PAGES_TUNNEL_TOKEN|home-infra|secret|Token del conector del tunnel de web-pages. Se obtiene con: terraform output -raw tunnel_token (en el repo web-pages)
SONARR_API_KEY|home-infra|secret|API key de Sonarr (Settings > General)
RADARR_API_KEY|home-infra|secret|API key de Radarr (Settings > General)
HA_LATITUDE|home-infra|text|Latitud de la casa para Home Assistant, ej. 9.9281
HA_LONGITUDE|home-infra|text|Longitud de la casa para Home Assistant, ej. -84.0907
HA_ELEVATION|home-infra|text|Elevacion en metros para Home Assistant, ej. 1150
ALEXA_CLIENT_ID|home-infra|text|Client ID de la skill de Alexa Smart Home
ALEXA_CLIENT_SECRET|home-infra|secret|Client secret de la skill de Alexa Smart Home
GMAIL_ADDRESS|home-infra|text|Gmail desde el que se envia el aviso de deploy
GMAIL_APP_PASSWORD|home-infra|secret|App password de Gmail (16 chars). Pegala SIN espacios.
CLOUDFLARE_API_TOKEN|web-pages|secret|Token Cloudflare para Terraform (Zone:DNS:Edit + Account:Cloudflare Tunnel:Edit)
CLOUDFLARE_ACCOUNT_ID|web-pages|text|Account ID de Cloudflare (dashboard > cualquier dominio > barra derecha)
EOF
}

repo_for() {
    case "$1" in
        home-infra) printf '%s' "$HOME_INFRA_REPO" ;;
        web-pages)  printf '%s' "$WEB_PAGES_REPO" ;;
        *) echo "repo desconocido: $1" >&2; exit 1 ;;
    esac
}

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "Error: falta $1. $2" >&2; exit 1; }
}

require gh "https://cli.github.com/"
require jq "https://jqlang.github.io/jq/"

if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh no esta autenticado. Corre: gh auth login" >&2
    exit 1
fi

# One API call per repo instead of one per secret.
EXISTING_HOME_INFRA="$(gh secret list --repo "$HOME_INFRA_REPO" --json name,updatedAt 2>/dev/null || echo '[]')"
EXISTING_WEB_PAGES="$(gh secret list --repo "$WEB_PAGES_REPO" --json name,updatedAt 2>/dev/null || echo '[]')"

existing_json_for() {
    case "$1" in
        home-infra) printf '%s' "$EXISTING_HOME_INFRA" ;;
        web-pages)  printf '%s' "$EXISTING_WEB_PAGES" ;;
    esac
}

secret_exists() {
    existing_json_for "$2" | jq -e --arg n "$1" 'any(.[]; .name == $n)' >/dev/null 2>&1
}

secret_updated_at() {
    existing_json_for "$2" | jq -r --arg n "$1" '.[] | select(.name == $n) | .updatedAt' 2>/dev/null | head -1
}

# Alphanumeric only, deliberately: these land in .env, which docker compose
# reads with --env-file, and compose interpolates $VAR inside values. A
# generated password containing $ (or a quote) would silently arrive at the
# container mangled.
gen_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 32
}

# Sets REPLY_VALUE. Prompts go to stderr so the caller's stdout stays clean.
REPLY_VALUE=""
read_value() {
    _rv_name="$1"; _rv_kind="$2"; _rv_hint="$3"
    printf "${DIM}    %s${NC}\n" "$_rv_hint" >&2
    if [ "$_rv_kind" = "text" ]; then
        printf "    %s = " "$_rv_name" >&2
        IFS= read -r REPLY_VALUE < /dev/tty || REPLY_VALUE=""
    else
        # `read -s` is a bashism; stty keeps this working under dash too.
        printf "    %s = (oculto) " "$_rv_name" >&2
        stty -echo < /dev/tty 2>/dev/null || true
        IFS= read -r REPLY_VALUE < /dev/tty || REPLY_VALUE=""
        stty echo < /dev/tty 2>/dev/null || true
        printf '\n' >&2
    fi
}

warn_if_awkward() {
    case "$2" in
        *'$'*)
            printf "${YELLOW}    Ojo: el valor contiene '\$'. docker compose interpola \$VAR en los valores del .env,\n    asi que puede llegar distinto al contenedor.${NC}\n" >&2
            ;;
    esac
    case "$1" in
        GMAIL_APP_PASSWORD)
            case "$2" in
                *' '*) printf "${YELLOW}    Ojo: Google muestra las app passwords con espacios; se pegan SIN espacios.${NC}\n" >&2 ;;
            esac
            ;;
    esac
}

set_secret() {
    _ss_name="$1"; _ss_repo_key="$2"; _ss_value="$3"
    if [ -z "$_ss_value" ]; then
        printf "${YELLOW}    vacio — no se guarda${NC}\n"
        return 1
    fi
    warn_if_awkward "$_ss_name" "$_ss_value"
    printf '%s' "$_ss_value" | gh secret set "$_ss_name" --repo "$(repo_for "$_ss_repo_key")" >/dev/null
    printf "${GREEN}    guardado en %s${NC}\n" "$(repo_for "$_ss_repo_key")"
    return 0
}

# Prompts for a value (offering generation when the secret supports it) and
# stores it. Returns non-zero if nothing was stored.
prompt_and_set() {
    _pas_name="$1"; _pas_repo="$2"; _pas_kind="$3"; _pas_hint="$4"
    if [ "$_pas_kind" = "gen" ]; then
        printf "    ¿generar uno aleatorio? [S/n] " >&2
        IFS= read -r _pas_ans < /dev/tty || _pas_ans=""
        case "$_pas_ans" in
            ""|s|S|y|Y)
                _pas_val="$(gen_password)"
                if set_secret "$_pas_name" "$_pas_repo" "$_pas_val"; then
                    printf "${DIM}    (generado, 32 chars alfanumericos)${NC}\n"
                    return 0
                fi
                return 1
                ;;
        esac
    fi
    read_value "$_pas_name" "$_pas_kind" "$_pas_hint"
    set_secret "$_pas_name" "$_pas_repo" "$REPLY_VALUE"
}

run_mode() {
    _mode="$1"
    _current_repo=""
    manifest | while IFS='|' read -r name repo kind hint; do
        [ -n "${name:-}" ] || continue

        if [ "$repo" != "$_current_repo" ]; then
            printf "\n${BLUE}=== %s ===${NC}\n" "$(repo_for "$repo")"
            _current_repo="$repo"
        fi

        if secret_exists "$name" "$repo"; then
            _status="presente (actualizado $(secret_updated_at "$name" "$repo"))"
            _present=yes
        else
            _status="FALTA"
            _present=no
        fi

        case "$_mode" in
            missing)
                if [ "$_present" = yes ]; then
                    printf "${DIM}  %-24s %s — se deja como esta${NC}\n" "$name" "$_status"
                    continue
                fi
                printf "${YELLOW}  %-24s %s${NC}\n" "$name" "$_status"
                prompt_and_set "$name" "$repo" "$kind" "$hint" || true
                ;;
            all)
                printf "  %-24s ${DIM}%s${NC}\n" "$name" "$_status"
                prompt_and_set "$name" "$repo" "$kind" "$hint" || true
                ;;
            review)
                if [ "$_present" = yes ]; then
                    printf "  %-24s ${DIM}%s${NC}\n" "$name" "$_status"
                    printf "    ¿rotar este secreto? [s/N] " >&2
                    IFS= read -r _ans < /dev/tty || _ans=""
                    case "$_ans" in
                        s|S|y|Y) prompt_and_set "$name" "$repo" "$kind" "$hint" || true ;;
                        *) printf "${DIM}    se deja como esta${NC}\n" ;;
                    esac
                else
                    printf "${YELLOW}  %-24s %s${NC}\n" "$name" "$_status"
                    printf "    ¿crearlo ahora? [S/n] " >&2
                    IFS= read -r _ans < /dev/tty || _ans=""
                    case "$_ans" in
                        ""|s|S|y|Y) prompt_and_set "$name" "$repo" "$kind" "$hint" || true ;;
                        *) printf "${DIM}    se deja sin crear${NC}\n" ;;
                    esac
                fi
                ;;
        esac
    done
}

report_orphans() {
    printf "\n${BLUE}=== secretos en GitHub que ningun workflow usa ===${NC}\n"
    _known="$(manifest | cut -d'|' -f1)"
    _found=0
    for _r in home-infra web-pages; do
        for _n in $(existing_json_for "$_r" | jq -r '.[].name'); do
            if ! printf '%s\n' "$_known" | grep -Fxq "$_n"; then
                printf "${YELLOW}  %s: %s${NC} ${DIM}(huerfano — se puede borrar: gh secret delete %s --repo %s)${NC}\n" \
                    "$(repo_for "$_r")" "$_n" "$_n" "$(repo_for "$_r")"
                _found=1
            fi
        done
    done
    [ "$_found" -eq 0 ] && printf "${DIM}  ninguno${NC}\n"
    return 0
}

MODE="${1:-}"
case "$MODE" in
    --all)     MODE=all ;;
    --missing) MODE=missing ;;
    --review)  MODE=review ;;
    "")
        printf "\n${BLUE}Secretos de GitHub Actions${NC}\n"
        printf "  %s y %s\n\n" "$HOME_INFRA_REPO" "$WEB_PAGES_REPO"
        printf "  1) Poblar TODOS         — pregunta por cada secreto y lo sobreescribe\n"
        printf "  2) Poblar los FALTANTES — solo los que aun no existen en GitHub\n"
        printf "  3) Revisar uno por uno  — muestra cuales existen y pregunta si rotar\n\n"
        printf "Opcion [1/2/3]: "
        IFS= read -r _opt || _opt=""
        case "$_opt" in
            1) MODE=all ;;
            2) MODE=missing ;;
            3) MODE=review ;;
            *) echo "Opcion invalida." >&2; exit 1 ;;
        esac
        ;;
    *)
        echo "Uso: $0 [--all | --missing | --review]" >&2
        exit 1
        ;;
esac

run_mode "$MODE"
report_orphans

printf "\n${GREEN}Listo.${NC}\n"
printf "${DIM}Los secretos llegan al server en el proximo deploy de home-infra,\n"
printf "que reescribe el .env desde ellos. Para aplicarlos ya: gh workflow run \"Deploy to homelab\" --repo %s${NC}\n" "$HOME_INFRA_REPO"
