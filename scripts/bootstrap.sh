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
    echo "Repository already exists at $REPO_DIR"
else
    echo "Cloning repository..."
    git clone "https://$GITHUB_PAT@github.com/$REPO.git" "$REPO_DIR"
fi

cd "$REPO_DIR"

exec ./init.sh
