#!/bin/sh

chmod +x ./scripts/*.sh

./scripts/github-config.sh
./scripts/install_docker.sh
./scripts/docker_services.sh
./scripts/install_runner.sh
sudo ./scripts/harden.sh
