KEY_NAME="id_ed25519_github"
KEY_PATH="$HOME/.ssh/$KEY_NAME"
EMAIL="jcgarcia1520@gmail.com"
USER_NAME="juank1520"

echo "SSH key for github"

if [ -f "$KEY_PATH" ]; then
    echo "SSH already exists: $KEY_PATH"
else
    echo "Generaing new SSH Key (ED25519)..."
    ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY_PATH" -N ""
    echo "Key generated succesfully"
fi

if [ -z "$SSH_AUTH_SOCK" ]; then
    echo "Iniciando ssh-agent..."
    eval "$(ssh-agent -s)"
fi

echo "===== Save this SSH key into your github authentications keys ======"
cat "$KEY_PATH.pub"
echo "===================================================================="

git config --global user.email "$EMAIL"
git config --global user.name "$USER_NAME"
