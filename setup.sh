#!/bin/bash
# setup.sh — Install Proton Pass SSH Agent & git PIN gate
# Run once on a new machine to wire everything up.

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SSH_DIR="$HOME/.ssh"
SOCKET_PATH="$SSH_DIR/proton-pass-agent.sock"
SSH_CONFIG="$SSH_DIR/config"

echo "=== Proton Pass SSH Agent Setup ==="
echo ""

# ── 1. Ensure directories exist ──────────────────────────────────────────────
mkdir -p "$BIN_DIR" "$SYSTEMD_DIR" "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ── 2. Copy scripts ──────────────────────────────────────────────────────────
echo "[1/6] Installing scripts to $BIN_DIR ..."
cp "$REPO_DIR/proton-pass-ssh-agent-wrapper.sh" "$BIN_DIR/"
cp "$REPO_DIR/proton-git-wrapper.sh"            "$BIN_DIR/"
cp "$REPO_DIR/setup-git-signing.sh"             "$BIN_DIR/"
chmod +x "$BIN_DIR/proton-pass-ssh-agent-wrapper.sh"
chmod +x "$BIN_DIR/proton-git-wrapper.sh"
chmod +x "$BIN_DIR/setup-git-signing.sh"

# ── 3. Install systemd service ───────────────────────────────────────────────
echo "[2/6] Installing systemd user service ..."
cp "$REPO_DIR/proton-pass-ssh-agent.service" "$SYSTEMD_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now proton-pass-ssh-agent.service
echo "      Service enabled and started."

# ── 4. Configure ~/.ssh/config to use Proton socket as IdentityAgent ─────────
echo "[3/6] Configuring ~/.ssh/config ..."
if ! grep -qF "proton-pass-agent.sock" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" <<EOF

# Proton Pass SSH Agent — use proton socket for all hosts
Host *
    IdentityAgent $SOCKET_PATH
EOF
    chmod 600 "$SSH_CONFIG"
    echo "      Added IdentityAgent to $SSH_CONFIG"
else
    echo "      IdentityAgent already in $SSH_CONFIG — skipped."
fi

# ── 5. Export SSH_AUTH_SOCK in shell configs ──────────────────────────────────
echo "[4/6] Configuring SSH_AUTH_SOCK in shell configs ..."

# bash / zsh
for SHELL_RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$SHELL_RC" ] || [[ "$SHELL_RC" == *".bashrc" ]]; then
        if ! grep -qF "proton-pass-agent.sock" "$SHELL_RC" 2>/dev/null; then
            {
                echo ""
                echo "# Proton Pass SSH Agent socket"
                echo "export SSH_AUTH_SOCK=\"$SOCKET_PATH\""
            } >> "$SHELL_RC"
            echo "      Added SSH_AUTH_SOCK to $SHELL_RC"
        else
            echo "      SSH_AUTH_SOCK already in $SHELL_RC — skipped."
        fi
    fi
done

# fish
FISH_CONFIG="$HOME/.config/fish/config.fish"
if command -v fish &>/dev/null; then
    mkdir -p "$(dirname "$FISH_CONFIG")"
    if ! grep -qF "proton-pass-agent.sock" "$FISH_CONFIG" 2>/dev/null; then
        {
            echo ""
            echo "# Proton Pass SSH Agent socket"
            echo "set -gx SSH_AUTH_SOCK \"$SOCKET_PATH\""
        } >> "$FISH_CONFIG"
        echo "      Added SSH_AUTH_SOCK to $FISH_CONFIG"
    else
        echo "      SSH_AUTH_SOCK already in $FISH_CONFIG — skipped."
    fi
fi

# ── 6. Source git auth wrapper ───────────────────────────────────────────────
echo "[5/6] Wiring git auth wrapper into shell configs ..."

# bash / zsh
for SHELL_RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$SHELL_RC" ] || [[ "$SHELL_RC" == *".bashrc" ]]; then
        if ! grep -qF "proton-git-wrapper.sh" "$SHELL_RC" 2>/dev/null; then
            {
                echo ""
                echo "# Proton Pass git auth gate"
                echo "source \"\$HOME/.local/bin/proton-git-wrapper.sh\""
            } >> "$SHELL_RC"
            echo "      Sourced git wrapper in $SHELL_RC"
        else
            echo "      Git wrapper already in $SHELL_RC — skipped."
        fi
    fi
done

# fish (uses a wrapper function via funcsave instead of source)
if command -v fish &>/dev/null; then
    if ! grep -qF "proton-git-wrapper" "$FISH_CONFIG" 2>/dev/null; then
        {
            echo ""
            echo "# Proton Pass git auth gate"
            echo "# Run: bass source ~/.local/bin/proton-git-wrapper.sh"
            echo "# Or use setup-git-signing.sh after login"
        } >> "$FISH_CONFIG"
        echo "      Fish: git wrapper note added to $FISH_CONFIG (requires 'bass' plugin for full support)"
    fi
fi

# ── 7. Set git to use SSH signing format (prevent GPG fallback) ───────────────
echo "[6/6] Configuring git to use SSH signing format ..."
git config --global gpg.format ssh
# defaultKeyCommand: git asks the SSH agent directly for a key.
# This means signing works immediately after unlock with no explicit user.signingkey needed.
git config --global gpg.ssh.defaultKeyCommand "ssh-add -L"
echo "      gpg.format=ssh and gpg.ssh.defaultKeyCommand set globally."

# ── Auto-configure git SSH signing if agent is already running ────────────────
echo ""
echo "Checking if Proton Pass is unlocked to auto-configure git signing..."

# Retry for up to 8 s — the systemd service may need a moment to start
KEYS=""
for i in 1 2 3 4; do
    KEYS=$(SSH_AUTH_SOCK="$SOCKET_PATH" ssh-add -L 2>/dev/null)
    if [[ -n "$KEYS" ]]; then break; fi
    echo "      Waiting for agent... ($i/4)"
    sleep 2
done

if [[ -n "$KEYS" ]]; then
    echo "      Agent is live — running setup-git-signing.sh automatically..."
    SSH_AUTH_SOCK="$SOCKET_PATH" bash "$BIN_DIR/setup-git-signing.sh"
else
    echo "      Agent not ready (Proton Pass may be locked or not logged in)."
    echo "      After unlocking, run:  setup-git-signing.sh"
    echo "      (git signing will still work via gpg.ssh.defaultKeyCommand once unlocked)"
fi

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Next steps:"
echo "  1. Reload your shell:"
echo "       bash/zsh:  source ~/.bashrc"
echo "       fish:      source ~/.config/fish/config.fish"
echo "  2. If not logged in yet:"
echo "       pass-cli login"
echo "       setup-git-signing.sh"
echo "  3. Test SSH:"
echo "       ssh -T git@github.com"
