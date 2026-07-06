#!/bin/sh
set -e

REPO="juank1520/home-infra"
REPO_DIR="$HOME/home-infra"

if [ -z "$GITHUB_PAT" ]; then
    echo "Error: GITHUB_PAT is required."
    echo "Run scripts/generate-install-cmd.sh on your personal computer to get the install command."
    exit 1
fi

if [ -d "$REPO_DIR" ]; then
    echo "Repository already exists at $REPO_DIR, pulling latest changes..."
    git -C "$REPO_DIR" pull
else
    echo "Cloning repository..."
    AUTH_HEADER="Authorization: Basic $(printf '%s:' "$GITHUB_PAT" | base64 | tr -d '\n')"
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=http.extraHeader \
    GIT_CONFIG_VALUE_0="$AUTH_HEADER" \
    git clone "https://github.com/$REPO.git" "$REPO_DIR"
    unset AUTH_HEADER
fi

cd "$REPO_DIR"

exec ./init.sh
