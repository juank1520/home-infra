#!/bin/sh
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root (sudo)"
    exit 1
fi

apt-get update
apt-get install -y zram-tools

systemctl enable --now zramswap.service

echo
echo "zram swap active:"
swapon --show
free -h
