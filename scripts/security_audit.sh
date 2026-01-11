#!/bin/sh

# =============================================================
#  Security Assestment Script - Ubuntu Server 25 (Raspberry Pi)
#  SOLO VALIDACIÓN (no modifica el sistema)
# =============================================================

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
NC="\033[0m"

OK=0
FAIL=0
WARN=0

ok()   { printf "${GREEN}[OK]${NC}     %s\n" "$1"; OK=$((OK+1)); }
fail() { printf "${RED}[FAIL]${NC}   %s\n        → %s\n" "$1" "$2"; FAIL=$((FAIL+1)); }
warn() { printf "${YELLOW}[WARN]${NC}   %s\n        → %s\n" "$1" "$2"; WARN=$((WARN+1)); }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must execute as root"
    exit 1
  fi
}

require_root

echo "=== Security System assestment ==="
echo

# ---------------------------------------------------------
# 1. Users and Sudo
# ---------------------------------------------------------

HUMAN_USERS=$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd)

USER_COUNT=$(echo "$HUMAN_USERS" | wc -w)
if [ "$USER_COUNT" -eq 1 ]; then
  ok "Esists just ONE human user ($HUMAN_USERS)"
else
  fail "Exists more than one human users: $HUMAN_USERS" \
       "You must delete the unneccesary human users, the recomendation is have just one"
fi

SUDO_USERS=$(getent group sudo | awk -F: '{print $4}')
if [ "$SUDO_USERS" = "$HUMAN_USERS" ]; then
  ok "Just main user must be in sudo group"
else
  fail "Users in sudo: $SUDO_USERS" \
       "Review the sudo group"
fi

NOPASSWD_MATCHES=$(sudo grep -R "NOPASSWD" /etc/sudoers /etc/sudoers.d 2>/dev/null)
NOPASSWD_FILES=$(echo "$NOPASSWD_MATCHES" | cut -d: -f1 | sort -u)
if [ -n "$NOPASSWD_MATCHES" ]; then
  fail "Exists rules sudo with NOPASSWD $NOPASSWD_FILES" \
       "Run the following command: 'sudo visudo -f $NOPASSWD_FILES' and replace NOPASSWD:ALL to ALL"
else
  ok "Doesn't exists sudo rules without passowords"
fi


# ---------------------------------------------------------
# 2. SSH
# ---------------------------------------------------------

SSH_PORTS=$(sudo ss -tulpn | awk '/sshd/ && /LISTEN/ {split($5,a,":"); print a[length(a)]}' | sort -u)
SSHD_CONFIG="/etc/ssh/sshd_config"

if !(echo "$SSH_PORTS" | grep -qx "22"); then
  ok "SSH is not using the default port (22)"
else
  fail "SSH is using the port 22" \
       "Change SSH 'Port' in $SSHD_CONFIG and reload ssh with the following command: 'sudo systemctl reload ssh'"
fi

SSH_PASSWORD_AUTH=$(sshd -T | awk '$1=="passwordauthentication" {print $2}')
if [ "$SSH_PASSWORD_AUTH" = "no" ]; then
  ok "PasswordAuthentication is disabled"
else
  fail "PasswordAuthentication is enabled" \
       "Change 'PasswordAuthentication no' in $SSHD_CONFIG"
fi

SSH_ROOT_LOGIN=$(sshd -T | awk '$1=="permitrootlogin" {print $2}')
if [ "$SSH_ROOT_LOGIN" = "no" ]; then
  ok "SSH root login is disabled"
else
  fail "PermitRootLogin no is disabled" \
       "Set 'PermitRootLogin no' in $SSHD_CONFIG"
fi

# ---------------------------------------------------------
# 3. Firewall (UFW)
# ---------------------------------------------------------

command -v ufw >/dev/null 2>&1 || fail "ufw is not installed" "Must install ufw"

if ufw status | grep -q "Status: active"; then
  ok "ufw is active"
else
  fail "ufw is not active" "Run command: sudo ufw enable"
fi

UFW_DEFAULTS=$(ufw status verbose | awk -F'Default: ' '/Default:/ {print $2}')
if echo "$UFW_DEFAULTS" | grep -q "deny (incoming)"; then
  ok "Default Policy: deny incoming"
else
  fail "Incoming policy is not deny" \
       "Run command: ufw default deny incoming"
fi

if echo "$UFW_DEFAULTS" | grep -q "allow (outgoing)"; then
  ok "Default Policy: allow outgoing"
else
  fail "Outcoming policy is not allow" \
       "Run command: ufw default allow outgoing"
fi

if ufw status | grep -q "22/tcp"; then
  fail "Puerto 22 is open" \
       "Delet rule running the command: ufw delete allow 22"
else
  ok "Port 22 is not open"
fi


# ---------------------------------------------------------
# 4. Network
# ---------------------------------------------------------

if ip link show wlan0 2>/dev/null | grep -q "UP"; then
  fail "Wi-Fi is activa" \
       "Copy network netplane configuration yaml 'system/50-cloud-init.yaml' into netplane config '/etc/netplan'"
else
  ok "Wi-Fi is disabled"
fi

# ---------------------------------------------------------
# 5. Docker
# ---------------------------------------------------------

if command -v docker >/dev/null 2>&1; then
  ok "Docker is insatalled"

  if ss -lntp | grep -q ":2375"; then
    fail "Docker is exposing socket TCP" \
         "Disable Docker TCP socket"
  else
    ok "Docker is not exposing socket TCP"
  fi

  if [ "$(stat -c %a /var/run/docker.sock)" -le 660 ]; then
    ok "Correct permissions on docker.sock"
  else
    fail "Insecure permissions on docker.sock" \
         "Adjust Docker permissions to 660"
  fi
else
  warn "Docker is not installed" "Run script ./scripts/install_docker.sh"
fi

# ---------------------------------------------------------
# 6. Updates
# ---------------------------------------------------------

if systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then
  ok "unattended-upgrades is enabled"
else
  fail "unattended-upgrades is not enabled" \
       "Enable automatic updates"
fi

if apt-mark showhold | grep -q .; then
  warn "Exists packages in hold" \
       "Review: apt-mark showhold"
else
  ok "There are not packages held"
fi

# ---------------------------------------------------------
# 7. Logging
# ---------------------------------------------------------

if [ -d /var/log/journal ]; then
  ok "Persistent logs enabled"
else
  warn "Logs are not persistant" \
       "Create journal running the following command: 'mkdir /var/log/journal' and reload journald"
fi


# ---------------------------------------------------------
# Results
# ---------------------------------------------------------

echo
echo "=== Security Summary ==="
printf "✔ OK:   %d\n" "$OK"
printf "✖ FAIL: %d\n" "$FAIL"
printf "⚠ WARN: %d\n" "$WARN"

[ "$FAIL" -eq 0 ] \
  && echo "General State: ACCEPTABLE (possible warnings)" \
  || echo "General State: Require Attention"

exit 0

