#!/bin/bash
# setup.sh — Install Proton Pass SSH Agent & git PIN gate
# Run once on a new machine to wire everything up.

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SOCKET_PATH="$HOME/.ssh/proton-pass-agent.sock"

echo "=== Proton Pass SSH Agent Setup ==="
echo ""

# ── 1. Ensure directories exist ──────────────────────────────────────────────
mkdir -p "$BIN_DIR" "$SYSTEMD_DIR" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# ── 2. Copy scripts ──────────────────────────────────────────────────────────
echo "[1/5] Installing scripts to $BIN_DIR ..."
cp "$REPO_DIR/proton-pass-ssh-agent-wrapper.sh" "$BIN_DIR/"
cp "$REPO_DIR/proton-git-wrapper.sh"            "$BIN_DIR/"
cp "$REPO_DIR/proton-pin-setup"                 "$BIN_DIR/"
chmod +x "$BIN_DIR/proton-pass-ssh-agent-wrapper.sh"
chmod +x "$BIN_DIR/proton-git-wrapper.sh"
chmod +x "$BIN_DIR/proton-pin-setup"

# ── 3. Install systemd service ───────────────────────────────────────────────
echo "[2/5] Installing systemd user service ..."
cp "$REPO_DIR/proton-pass-ssh-agent.service" "$SYSTEMD_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now proton-pass-ssh-agent.service
echo "      Service enabled and started."

# ── 4. Configure SSH to use the Proton socket ────────────────────────────────
echo "[3/5] Configuring SSH_AUTH_SOCK ..."
SSH_CONFIG_LINE="export SSH_AUTH_SOCK=\"$SOCKET_PATH\""
SHELL_RC="$HOME/.bashrc"
if ! grep -qF "proton-pass-agent.sock" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# Proton Pass SSH Agent socket" >> "$SHELL_RC"
    echo "$SSH_CONFIG_LINE" >> "$SHELL_RC"
    echo "      Added SSH_AUTH_SOCK export to $SHELL_RC"
else
    echo "      SSH_AUTH_SOCK already configured in $SHELL_RC — skipped."
fi

# ── 5. Source git PIN wrapper ─────────────────────────────────────────────────
echo "[4/5] Wiring git PIN wrapper into $SHELL_RC ..."
SOURCE_LINE="source \"\$HOME/.local/bin/proton-git-wrapper.sh\""
if ! grep -qF "proton-git-wrapper.sh" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# Proton Pass git PIN gate" >> "$SHELL_RC"
    echo "$SOURCE_LINE" >> "$SHELL_RC"
    echo "      Git wrapper sourced in $SHELL_RC"
else
    echo "      Git wrapper already in $SHELL_RC — skipped."
fi

# ── 6. Set up PIN (interactive) ───────────────────────────────────────────────
echo "[5/5] Setting up git PIN ..."
if [ ! -f "$HOME/.config/proton-pass-pin-hash" ]; then
    "$BIN_DIR/proton-pin-setup"
else
    echo "      PIN already set — skipped. Run 'proton-pin-setup' to change it."
fi

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Next steps:"
echo "  1. Run:  source ~/.bashrc"
echo "  2. Log into Proton Pass:  pass-cli auth login"
echo "  3. The SSH agent will start automatically with the systemd service."
echo "  4. Test SSH:  ssh -T git@github.com"
echo "  5. To lock the git PIN session:  proton-lock"
