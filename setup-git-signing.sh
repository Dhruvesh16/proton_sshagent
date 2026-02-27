#!/bin/bash
# setup-git-signing.sh — Configure git to sign commits via Proton Pass SSH key
# Run this AFTER logging in with:  pass-cli login
# The Proton Pass SSH agent must already be running (systemd service).

set -e

SOCKET_PATH="${SSH_AUTH_SOCK:-$HOME/.ssh/proton-pass-agent.sock}"
ALLOWED_SIGNERS="$HOME/.ssh/allowed_signers"
EMAIL=$(git config --global user.email 2>/dev/null || echo "")

echo "=== Proton Pass git SSH Signing Setup ==="
echo ""

# ── 1. Check the agent socket is live ────────────────────────────────────────
if ! SSH_AUTH_SOCK="$SOCKET_PATH" ssh-add -l &>/dev/null; then
    echo "ERROR: Cannot contact the SSH agent at $SOCKET_PATH"
    echo "       Make sure you are logged in:  pass-cli login"
    echo "       And the service is running:   systemctl --user status proton-pass-ssh-agent"
    exit 1
fi

# ── 2. List available keys ────────────────────────────────────────────────────
echo "Keys available in Proton Pass agent:"
SSH_AUTH_SOCK="$SOCKET_PATH" ssh-add -L
echo ""

# Pick first key automatically; if multiple, let user choose
KEYS=()
while IFS= read -r line; do
    KEYS+=("$line")
done < <(SSH_AUTH_SOCK="$SOCKET_PATH" ssh-add -L)

if [ "${#KEYS[@]}" -eq 0 ]; then
    echo "ERROR: No SSH keys found in the agent."
    echo "       Add keys via Proton Pass app under 'SSH Key' items."
    exit 1
elif [ "${#KEYS[@]}" -eq 1 ]; then
    CHOSEN_KEY="${KEYS[0]}"
    echo "Using the only available key."
else
    echo "Multiple keys found. Enter the number of the key to use for signing:"
    for i in "${!KEYS[@]}"; do
        echo "  [$((i+1))] ${KEYS[$i]}"
    done
    read -r -p "Choice [1]: " choice
    choice="${choice:-1}"
    CHOSEN_KEY="${KEYS[$((choice-1))]}"
fi

echo ""
echo "Selected key: ${CHOSEN_KEY##* }"   # print just the comment/name

# ── 3. Save public key file ───────────────────────────────────────────────────
PUBKEY_FILE="$HOME/.ssh/proton-signing.pub"
echo "$CHOSEN_KEY" > "$PUBKEY_FILE"
chmod 644 "$PUBKEY_FILE"
echo "Public key saved to $PUBKEY_FILE"

# ── 4. Configure git global signing settings ──────────────────────────────────
git config --global gpg.format ssh
git config --global user.signingkey "$PUBKEY_FILE"
git config --global commit.gpgsign true
git config --global tag.gpgsign true
echo "Git configured to sign commits and tags with SSH key."

# ── 5. Update allowed_signers file ───────────────────────────────────────────
touch "$ALLOWED_SIGNERS"
chmod 644 "$ALLOWED_SIGNERS"

if [ -z "$EMAIL" ]; then
    read -r -p "Enter your git email for allowed_signers: " EMAIL
fi

SIGNERS_ENTRY="$EMAIL $CHOSEN_KEY"
if ! grep -qF "${CHOSEN_KEY%% *}" "$ALLOWED_SIGNERS" 2>/dev/null; then
    echo "$SIGNERS_ENTRY" >> "$ALLOWED_SIGNERS"
    echo "Added key to $ALLOWED_SIGNERS"
else
    echo "Key already in $ALLOWED_SIGNERS — skipped."
fi

# Ensure git knows where the allowed_signers file is
git config --global gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"

# ── 6. Point SSH_AUTH_SOCK at proton socket for signing ───────────────────────
# The git ssh-keygen signer inherits SSH_AUTH_SOCK from the environment.
# Remind the user to have it set.
if [ "${SSH_AUTH_SOCK}" != "$SOCKET_PATH" ]; then
    echo ""
    echo "NOTE: SSH_AUTH_SOCK is not pointing at the Proton socket."
    echo "      Make sure your shell has:  export SSH_AUTH_SOCK=\"$SOCKET_PATH\""
    echo "      (setup.sh adds this automatically)"
fi

echo ""
echo "=== Git signing configured! ==="
echo ""
echo "Test it with:"
echo "  git commit --allow-empty -m 'test signing' -S"
echo "  git log --show-signature -1"
