#!/bin/sh

chmod +x ./scripts/*.sh

if [ ! -f ./.env ]; then
    cp ./.env.example ./.env
    chmod 600 ./.env
fi

./scripts/github-config.sh
./scripts/install_docker.sh
./scripts/free_dns_port.sh
./scripts/docker_services.sh
./scripts/install_runner.sh
scripts/setup_zram.sh
sudo ./scripts/harden.sh
