#!/bin/sh

# Source .env for SSH_PORT if available
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

SSH_PORT="${SSH_PORT:-2222}"
SSHD_CONFIG="/etc/ssh/sshd_config"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"

OK=0
FIXED=0
FAIL=0

ok()    { printf "${GREEN}[OK]${NC}     %s\n" "$1";                         OK=$((OK+1)); }
fixed() { printf "${BLUE}[FIXED]${NC}  %s\n" "$1";                       FIXED=$((FIXED+1)); }
fail()  { printf "${RED}[FAIL]${NC}   %s\n         → %s\n" "$1" "$2";   FAIL=$((FAIL+1)); }
warn()  { printf "${YELLOW}[WARN]${NC}   %s\n         → %s\n" "$1" "$2"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must run as root"
        exit 1
    fi
}

# OpenSSH 10.2+ on Ubuntu 26.04 requires this directory for sshd -T
sshd_config_ready() {
    mkdir -p /run/sshd
}

# Set or replace a directive in sshd_config
sshd_set() {
    DIRECTIVE="$1"
    VALUE="$2"
    if grep -qE "^#*${DIRECTIVE} " "$SSHD_CONFIG"; then
        sed -i "s|^#*${DIRECTIVE} .*|${DIRECTIVE} ${VALUE}|" "$SSHD_CONFIG"
    else
        echo "${DIRECTIVE} ${VALUE}" >> "$SSHD_CONFIG"
    fi
}

require_root
sshd_config_ready

echo "=== Security Hardening - Ubuntu 26.04 (homeserver) ==="
echo

# ---------------------------------------------------------
# SSH
# ---------------------------------------------------------
echo "--- SSH ---"

CURRENT_PORT=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2}')
if [ "$CURRENT_PORT" != "22" ]; then
    ok "SSH not using default port (port $CURRENT_PORT)"
else
    sshd_set "Port" "$SSH_PORT"
    systemctl reload ssh
    CURRENT_PORT=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2}')
    if [ "$CURRENT_PORT" != "22" ]; then
        fixed "SSH port changed to $SSH_PORT"
    else
        fail "SSH port" "Could not change port. Edit $SSHD_CONFIG manually."
    fi
fi

PASS_AUTH=$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication" {print $2}')
if [ "$PASS_AUTH" = "no" ]; then
    ok "PasswordAuthentication disabled"
else
    sshd_set "PasswordAuthentication" "no"
    systemctl reload ssh
    PASS_AUTH=$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication" {print $2}')
    if [ "$PASS_AUTH" = "no" ]; then
        fixed "PasswordAuthentication disabled"
    else
        fail "PasswordAuthentication" "Could not disable. Edit $SSHD_CONFIG manually."
    fi
fi

ROOT_LOGIN=$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin" {print $2}')
if [ "$ROOT_LOGIN" = "no" ]; then
    ok "PermitRootLogin disabled"
else
    sshd_set "PermitRootLogin" "no"
    systemctl reload ssh
    ROOT_LOGIN=$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin" {print $2}')
    if [ "$ROOT_LOGIN" = "no" ]; then
        fixed "PermitRootLogin disabled"
    else
        fail "PermitRootLogin" "Could not disable. Edit $SSHD_CONFIG manually."
    fi
fi

echo

# ---------------------------------------------------------
# Firewall (UFW)
# ---------------------------------------------------------
echo "--- Firewall (UFW) ---"

if ! ufw status | grep -q "Status: active"; then
    ufw default deny incoming  >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow "$SSH_PORT/tcp"  >/dev/null 2>&1
    ufw --force enable         >/dev/null 2>&1
fi

if ufw status | grep -q "Status: active"; then
    ok "UFW active"
else
    fail "UFW" "Could not enable UFW"
fi

if ufw status verbose | grep -q "deny (incoming)"; then
    ok "UFW default deny incoming"
else
    ufw default deny incoming >/dev/null 2>&1
    if ufw status verbose | grep -q "deny (incoming)"; then
        fixed "UFW default deny incoming set"
    else
        fail "UFW incoming policy" "Run: ufw default deny incoming"
    fi
fi

if ufw status verbose | grep -q "allow (outgoing)"; then
    ok "UFW default allow outgoing"
else
    ufw default allow outgoing >/dev/null 2>&1
    if ufw status verbose | grep -q "allow (outgoing)"; then
        fixed "UFW default allow outgoing set"
    else
        fail "UFW outgoing policy" "Run: ufw default allow outgoing"
    fi
fi

if ufw status | grep -qE "^22[/ ]"; then
    ufw delete allow 22     >/dev/null 2>&1
    ufw delete allow 22/tcp >/dev/null 2>&1
    if ufw status | grep -qE "^22[/ ]"; then
        fail "UFW port 22" "Could not remove port 22. Run: ufw delete allow 22"
    else
        fixed "Port 22 removed from UFW"
    fi
else
    ok "Port 22 not open in UFW"
fi

if ufw status | grep -q "$SSH_PORT/tcp"; then
    ok "SSH port $SSH_PORT open in UFW"
else
    ufw allow "$SSH_PORT/tcp" >/dev/null 2>&1
    if ufw status | grep -q "$SSH_PORT/tcp"; then
        fixed "Port $SSH_PORT opened in UFW"
    else
        fail "UFW SSH port" "Could not open port $SSH_PORT"
    fi
fi

echo

# ---------------------------------------------------------
# Network
# ---------------------------------------------------------
echo "--- Network ---"

if ip link show wlan0 2>/dev/null | grep -q " UP "; then
    if rfkill block wifi 2>/dev/null; then
        if ! ip link show wlan0 2>/dev/null | grep -q " UP "; then
            fixed "Wi-Fi blocked via rfkill"
        else
            warn "Wi-Fi still UP after rfkill" \
                 "Apply netplan: sudo cp system/50-cloud-init.yaml /etc/netplan/ && sudo netplan apply"
        fi
    else
        fail "Wi-Fi active" "Run: sudo cp system/50-cloud-init.yaml /etc/netplan/ && sudo netplan apply"
    fi
else
    ok "Wi-Fi disabled"
fi

echo

# ---------------------------------------------------------
# Docker
# ---------------------------------------------------------
echo "--- Docker ---"

if command -v docker >/dev/null 2>&1; then
    if ss -lntp | grep -q ":2375"; then
        fail "Docker TCP socket exposed" \
             "Set {\"hosts\":[\"unix:///var/run/docker.sock\"]} in /etc/docker/daemon.json"
    else
        ok "Docker not exposing TCP socket"
    fi

    DOCKER_SOCK="/var/run/docker.sock"
    if [ -S "$DOCKER_SOCK" ]; then
        SOCK_PERMS=$(stat -c %a "$DOCKER_SOCK")
        if [ "$SOCK_PERMS" -le 660 ]; then
            ok "docker.sock permissions correct ($SOCK_PERMS)"
        else
            chmod 660 "$DOCKER_SOCK"
            SOCK_PERMS=$(stat -c %a "$DOCKER_SOCK")
            if [ "$SOCK_PERMS" -le 660 ]; then
                fixed "docker.sock permissions corrected to 660"
            else
                fail "docker.sock permissions" "Run: chmod 660 /var/run/docker.sock"
            fi
        fi
    fi
else
    warn "Docker not installed" "Run: ./scripts/install_docker.sh"
fi

echo

# ---------------------------------------------------------
# Updates
# ---------------------------------------------------------
echo "--- Updates ---"

if systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then
    ok "unattended-upgrades enabled"
else
    systemctl enable --now unattended-upgrades >/dev/null 2>&1
    if systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then
        fixed "unattended-upgrades enabled"
    else
        fail "unattended-upgrades" "Run: systemctl enable --now unattended-upgrades"
    fi
fi

echo

# ---------------------------------------------------------
# Logs
# ---------------------------------------------------------
echo "--- Logs ---"

if [ -d /var/log/journal ]; then
    ok "Persistent logs enabled"
else
    mkdir -p /var/log/journal
    systemctl restart systemd-journald
    if [ -d /var/log/journal ]; then
        fixed "Persistent logs enabled"
    else
        fail "Persistent logs" "Run: mkdir /var/log/journal && systemctl restart systemd-journald"
    fi
fi

echo

# ---------------------------------------------------------
# Summary
# ---------------------------------------------------------
echo "=== Summary ==="
printf "${GREEN}✔ OK:     %d${NC}\n" "$OK"
printf "${BLUE}⚡ FIXED:  %d${NC}\n" "$FIXED"
printf "${RED}✖ FAIL:   %d${NC}\n" "$FAIL"
echo
[ "$FAIL" -eq 0 ] \
    && printf "${GREEN}State: SECURE${NC}\n" \
    || printf "${RED}State: Requires manual attention${NC}\n"
