#!/bin/sh
set -e

echo "Validatin if socker is insalled"
if command -v docker >/dev/null 2>&1; then

  # Create virtual links to handle docker inicialization with systemctl
  sudo ln -sf ${HOME}/home-infra/system/docker-compose@.service /etc/systemd/system/docker-compose@.service
  sudo ln -sf ${HOME}/home-infra/system/stacks.target /etc/systemd/system/stacks.target

  # Enable stacks.target to inicilize when the system starts
  sudo systemctl enable stacks.target

  # Link docker services into stack.target docker-compose@DOCKER-FILE-NAME
  sudo systemctl enable docker-compose@networks
  sudo systemctl enable docker-compose@pi-hole
  sudo systemctl enable docker-compose@traefik
  sudo systemctl enable docker-compose@qbittorrent
  sudo systemctl enable docker-compose@sonarr
  sudo systemctl enable docker-compose@radarr
  sudo systemctl enable docker-compose@prowlarr
  sudo systemctl enable docker-compose@jellyfin
  sudo systemctl enable docker-compose@cups
fi
