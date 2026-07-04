#!/bin/sh
set -e
RESOLVED_CONF="/etc/systemd/resolved.conf"

if grep -qE '^[[:space:]]*DNSStubListener[[:space:]]*=[[:space:]]*no' "$RESOLVED_CONF" 2>/dev/null; then
    echo "systemd-resolved stub listener already disabled."
    exit 0
fi

echo "Freeing port 53 from systemd-resolved for Pi-hole..."

if grep -qE '^[[:space:]]*#?[[:space:]]*DNSStubListener[[:space:]]*=' "$RESOLVED_CONF"; then
    sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*DNSStubListener[[:space:]]*=.*|DNSStubListener=no|' "$RESOLVED_CONF"
else
    echo 'DNSStubListener=no' | sudo tee -a "$RESOLVED_CONF" >/dev/null
fi

sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

sudo systemctl restart systemd-resolved

if ss -tulpn 2>/dev/null | grep -q 'systemd-resolve.*:53'; then
    echo "WARNING: systemd-resolved still listening on port 53." >&2
else
    echo "Port 53 freed for Pi-hole."
fi
