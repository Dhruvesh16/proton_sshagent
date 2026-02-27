#!/bin/bash
# setup-git-signing.sh — Configure git SSH signing via Proton Pass agent
#
# Like 1Password: the agent serves your signing key automatically.
# Run this once after unlocking Proton Pass for the first time.

set -e

SOCKET_PATH="${SSH_AUTH_SOCK:-$HOME/.ssh/proton-pass-agent.sock}"
ALLOWED_SIGNERS="$HOME/.ssh/allowed_signers"
PUBKEY_FILE="$HOME/.ssh/proton-signing.pub"
EMAIL=$(git config --global user.email 2>/dev/null || echo "")

echo "=== Proton Pass — Git SSH Signing Setup ==="
echo ""

# ── 1. Verify agent is live ──────────────────────────────────────────────────
if ! SSH_AUTH_SOCK="$SOCKET_PATH" ssh-add -l &>/dev/null; then
    echo "❌ Cannot reach the SSH agent at $SOCKET_PATH"
    echo ""
    echo "   Make sure Proton Pass is unlocked, then try again."
    echo "   Check service: systemctl --user status proton-pass-ssh-agent"
    exit 1
fi

# ── 2. List available keys ───────────────────────────────────────────────────
echo "Keys in Proton Pass agent:"
echo ""
KEYS=()
while IFS= read -r line; do
    KEYS+=("$line")
done < <(SSH_AUTH_SOCK="$SOCKET_PATH" ssh-add -L)

if [[ ${#KEYS[@]} -eq 0 ]]; then
    echo "❌ No SSH keys found. Add keys in the Proton Pass app under SSH Keys."
    exit 1
fi

for i in "${!KEYS[@]}"; do
    echo "  [$((i+1))] ${KEYS[$i]##* }"
done
echo ""

# ── 3. Choose key ────────────────────────────────────────────────────────────
if [[ ${#KEYS[@]} -eq 1 ]]; then
    CHOSEN_KEY="${KEYS[0]}"
    echo "Using the only available key."
else
    read -r -p "Choose signing key [1]: " choice
    choice="${choice:-1}"
    CHOSEN_KEY="${KEYS[$((choice-1))]}"
fi

echo "  → ${CHOSEN_KEY##* }"
echo ""

# ── 4. Save public key ───────────────────────────────────────────────────────
echo "$CHOSEN_KEY" > "$PUBKEY_FILE"
chmod 644 "$PUBKEY_FILE"

# ── 5. Configure git (like 1Password — automatic SSH signing) ────────────────
git config --global gpg.format ssh
git config --global user.signingkey "$PUBKEY_FILE"
git config --global commit.gpgsign true
git config --global tag.gpgsign true
echo "✅ Git configured for SSH signing."

# ── 6. Update allowed_signers ────────────────────────────────────────────────
touch "$ALLOWED_SIGNERS"
chmod 644 "$ALLOWED_SIGNERS"

if [[ -z "$EMAIL" ]]; then
    read -r -p "Your git email for allowed_signers: " EMAIL
fi

SIGNERS_ENTRY="$EMAIL $CHOSEN_KEY"
if ! grep -qF "${CHOSEN_KEY%% *}" "$ALLOWED_SIGNERS" 2>/dev/null; then
    echo "$SIGNERS_ENTRY" >> "$ALLOWED_SIGNERS"
    echo "✅ Key added to $ALLOWED_SIGNERS"
else
    echo "   Key already in allowed_signers — skipped."
fi

git config --global gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"

# ── 7. Verify SSH_AUTH_SOCK ───────────────────────────────────────────────────
if [[ "${SSH_AUTH_SOCK}" != "$SOCKET_PATH" ]]; then
    echo ""
    echo "⚠️  SSH_AUTH_SOCK is not pointing to the Proton socket."
    echo "   Ensure your shell has:  export SSH_AUTH_SOCK=\"$SOCKET_PATH\""
fi

echo ""
echo "=== Done! Test with: ==="
echo "  git commit --allow-empty -m 'test signing' -S"
echo "  git log --show-signature -1"
