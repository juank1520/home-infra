#!/bin/sh
set -e

echo "Validatin if socker is insalled"
if command -v docker >/dev/null 2>&1; then

  REPO_DIR="${HOME}/home-infra"

  # Render docker-compose@.service with the real repo path (WorkingDirectory can't use $HOME)
  sed "s#__REPO_DIR__#${REPO_DIR}#g" "${REPO_DIR}/system/docker-compose@.service" | sudo tee /etc/systemd/system/docker-compose@.service >/dev/null
  sudo ln -sf ${REPO_DIR}/system/stacks.target /etc/systemd/system/stacks.target

  sudo systemctl daemon-reload

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

  # Start all stacks.target
  sudo systemctl start stacks.target
fi
