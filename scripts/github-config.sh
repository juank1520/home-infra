#!/bin/sh
set -e

KEY_NAME="id_ed25519_github"
KEY_PATH="$HOME/.ssh/$KEY_NAME"
EMAIL="jcgarcia1520@gmail.com"
USER_NAME="juank1520"

echo "SSH key for github"

if [ -f "$KEY_PATH" ]; then
    echo "SSH key already exists: $KEY_PATH"
else
    echo "Generating new SSH Key (ED25519)..."
    ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY_PATH" -N ""
    echo "Key generated successfully"
fi

if [ -z "$SSH_AUTH_SOCK" ]; then
    echo "Starting ssh-agent..."
    eval "$(ssh-agent -s)"
fi
ssh-add "$KEY_PATH"

SSH_CONFIG="$HOME/.ssh/config"
if ! grep -q "Host github.com" "$SSH_CONFIG" 2>/dev/null; then
    echo "Configuring SSH client for GitHub..."
    mkdir -p "$HOME/.ssh"
    cat >> "$SSH_CONFIG" << EOF
Host github.com
    IdentityFile $KEY_PATH
    User git
EOF
    chmod 600 "$SSH_CONFIG"
fi

git config --global user.email "$EMAIL"
git config --global user.name "$USER_NAME"

if [ -n "$GITHUB_PAT" ]; then
    echo "Registering SSH key in GitHub via API..."
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST https://api.github.com/user/keys \
        -H "Authorization: token $GITHUB_PAT" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"$(hostname)\",\"key\":\"$(cat $KEY_PATH.pub)\"}")

    if [ "$HTTP_STATUS" = "201" ]; then
        echo "SSH key registered successfully."
    elif [ "$HTTP_STATUS" = "422" ]; then
        echo "SSH key already registered in GitHub."
    else
        echo "Warning: Could not register SSH key (HTTP $HTTP_STATUS). Add it manually:"
        cat "$KEY_PATH.pub"
    fi

    if git remote get-url origin 2>/dev/null | grep -q "https://"; then
        echo "Switching remote from HTTPS to SSH..."
        git remote set-url origin "git@github.com:$USER_NAME/home-infra.git"
    fi
else
    echo "===== Add this SSH key to your GitHub account ======"
    cat "$KEY_PATH.pub"
    echo "====================================================="
fi
