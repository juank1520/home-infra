#!/bin/sh

./scripts/github-config.sh
./scripts/install_docker.sh
./scripts/docker_services.sh
sudo ./scripts/harden.sh
