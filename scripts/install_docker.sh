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
        echo "$SUDO_USER was added to the docker group."
        echo "This setup script uses sudo for all docker commands, so no action is needed now."
        echo "To run docker without sudo as $SUDO_USER, log out and log back in first."
    fi

    echo "Docker instalation is done."
    docker --version

fi

DROPIN_DIR="/etc/systemd/system/docker.service.d"
sudo mkdir -p "$DROPIN_DIR"
sudo tee "${DROPIN_DIR}/min-api.conf" >/dev/null <<'EOF'
[Service]
Environment=DOCKER_MIN_API_VERSION=1.24
EOF

sudo systemctl daemon-reload

if [ "$(sudo docker version --format '{{.Server.MinAPIVersion}}' 2>/dev/null)" != "1.24" ]; then
    echo "Applying DOCKER_MIN_API_VERSION=1.24 (restarting Docker)..."
    sudo systemctl restart docker
else
    echo "Docker minimum API version already 1.24."
fi
