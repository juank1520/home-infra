#!/bin/sh

set -e
echo "Verifying if Docker is installed..."

if command -v docker >/dev/null 2>&1; then
    echo "Docker is already installed."
    docker --version
else

    echo "Docker is not installed."
    echo "Installing Docker..."

    sudo apt update

    sudo apt install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    sudo mkdir -p /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update

    sudo apt install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    sudo systemctl enable docker
    sudo systemctl start docker

    if [ -n "$SUDO_USER" ]; then
        sudo usermod -aG docker "$SUDO_USER"
        echo "$SUDO_USER user added to goup docker."
        echo "Must loguout session and login again."
    fi

    echo "Docker instalation is done."
    docker --version

fi
