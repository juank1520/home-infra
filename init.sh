#!/bin/sh

chmod 750 ./scripts/*.sh

if [ ! -f ./.env ]; then
    cp ./.env.example ./.env
    chmod 600 ./.env
fi

./scripts/github-config.sh
sudo ./scripts/setup_zram.sh
./scripts/install_docker.sh
./scripts/free_dns_port.sh
./scripts/docker_services.sh
./scripts/install_runner.sh
sudo ./scripts/harden.sh
