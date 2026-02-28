#!/bin/bash
# setup.sh — Proton Pass Native SSH Agent Setup
#
# Sets up Proton Pass as your system SSH agent using pass-cli:
#   1. One socket path for everything (SSH, git signing, etc.)
#   2. Authenticate via pass-cli login (interactive terminal auth)
#   3. Automatic login prompts when keys are needed (git push/sign)
#   4. Session timeout purges cached keys for security
#
# Run as:  source ./setup.sh   (or: bash ./setup.sh)

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SSH_DIR="$HOME/.ssh"
SOCKET_PATH="$SSH_DIR/proton-pass-agent.sock"
SSH_CONFIG="$SSH_DIR/config"

echo "╔══════════════════════════════════════════════════════╗"
echo "║   Proton Pass — Native SSH Agent Setup              ║"
echo "║   (pass-cli authentication, no desktop app needed)  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── 1. Ensure directories ────────────────────────────────────────────────────
mkdir -p "$BIN_DIR" "$SYSTEMD_DIR" "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ── 2. Detect pass-cli ────────────────────────────────────────────────────────
echo "[1/5] Detecting pass-cli..."

PASS_CLI=""
for candidate in \
    "$(command -v pass-cli 2>/dev/null || true)" \
    "$HOME/.local/bin/pass-cli" \
    "/usr/bin/pass-cli" \
    "/usr/local/bin/pass-cli"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        PASS_CLI="$candidate"
        break
    fi
done

if [[ -n "$PASS_CLI" ]]; then
    echo "      ✅ pass-cli found at $PASS_CLI"
else
    echo "      ⚠️  pass-cli not found."
    echo "         Download from: https://github.com/ProtonPass/pass-cli-linux/releases"
    echo ""
    read -r -p "Continue anyway? [y/N] " cont
    [[ "$cont" =~ ^[Yy] ]] || exit 1
fi

# ── 3. Install scripts ───────────────────────────────────────────────────────
echo ""
echo "[2/5] Installing agent scripts to $BIN_DIR ..."
cp "$REPO_DIR/proton-pass-ssh-agent-wrapper.sh" "$BIN_DIR/"
cp "$REPO_DIR/proton-git-wrapper.sh"            "$BIN_DIR/"
cp "$REPO_DIR/setup-git-signing.sh"             "$BIN_DIR/"
chmod +x "$BIN_DIR/proton-pass-ssh-agent-wrapper.sh"
chmod +x "$BIN_DIR/proton-git-wrapper.sh"
chmod +x "$BIN_DIR/setup-git-signing.sh"
echo "      Done."

# ── 4. Install & start systemd service ───────────────────────────────────────
echo ""
echo "[3/5] Installing systemd user service ..."
cp "$REPO_DIR/proton-pass-ssh-agent.service" "$SYSTEMD_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now proton-pass-ssh-agent.service
echo "      Service enabled and started."

# ── 5. Configure SSH ──────────────────────────────────────────────────────────
echo ""
echo "[4/5] Configuring SSH to use Proton Pass agent..."

# ~/.ssh/config — IdentityAgent directive
if ! grep -qF "proton-pass-agent.sock" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" <<EOF

# ── Proton Pass SSH Agent (pass-cli native) ──
Host *
    IdentityAgent $SOCKET_PATH
EOF
    chmod 600 "$SSH_CONFIG"
    echo "      Added IdentityAgent to ~/.ssh/config"
else
    echo "      IdentityAgent already configured — skipped."
fi

# SSH_AUTH_SOCK in shell rc files
for SHELL_RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$SHELL_RC" ]] || [[ "$SHELL_RC" == *".bashrc" ]]; then
        if ! grep -qF "proton-pass-agent.sock" "$SHELL_RC" 2>/dev/null; then
            {
                echo ""
                echo "# Proton Pass SSH Agent (pass-cli native)"
                echo "export SSH_AUTH_SOCK=\"$SOCKET_PATH\""
            } >> "$SHELL_RC"
            echo "      Added SSH_AUTH_SOCK to $SHELL_RC"
        else
            echo "      SSH_AUTH_SOCK already in $SHELL_RC — skipped."
        fi
    fi
done

# fish shell
FISH_CONFIG="$HOME/.config/fish/config.fish"
if command -v fish &>/dev/null; then
    mkdir -p "$(dirname "$FISH_CONFIG")"
    if ! grep -qF "proton-pass-agent.sock" "$FISH_CONFIG" 2>/dev/null; then
        {
            echo ""
            echo "# Proton Pass SSH Agent (pass-cli native)"
            echo "set -gx SSH_AUTH_SOCK \"$SOCKET_PATH\""
        } >> "$FISH_CONFIG"
        echo "      Added SSH_AUTH_SOCK to $FISH_CONFIG"
    else
        echo "      SSH_AUTH_SOCK already in $FISH_CONFIG — skipped."
    fi
fi

# ── 6. Wire git wrapper + configure signing ──────────────────────────────────
echo ""
echo "[5/5] Configuring git integration..."

# Source git wrapper in shell rc files
for SHELL_RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$SHELL_RC" ]] || [[ "$SHELL_RC" == *".bashrc" ]]; then
        if ! grep -qF "proton-git-wrapper.sh" "$SHELL_RC" 2>/dev/null; then
            {
                echo ""
                echo "# Proton Pass git integration (transparent unlock on push/sign)"
                echo "source \"\$HOME/.local/bin/proton-git-wrapper.sh\""
            } >> "$SHELL_RC"
            echo "      Sourced git wrapper in $SHELL_RC"
        else
            echo "      Git wrapper already in $SHELL_RC — skipped."
        fi
    fi
done

# fish shell
if command -v fish &>/dev/null; then
    if ! grep -qF "proton-git-wrapper" "$FISH_CONFIG" 2>/dev/null; then
        {
            echo ""
            echo "# Proton Pass git integration"
            echo "# For fish, use: bass source ~/.local/bin/proton-git-wrapper.sh"
        } >> "$FISH_CONFIG"
        echo "      Fish: git wrapper note added (requires 'bass' plugin)"
    fi
fi

# Git SSH signing format (agent serves keys automatically)
git config --global gpg.format ssh
git config --global gpg.ssh.defaultKeyCommand "ssh-add -L"
echo "      Git SSH signing format configured."

# ── Auto-configure git signing if agent is already running ────────────────────
echo ""
echo "Checking if Proton Pass is unlocked..."

KEYS=""
for i in 1 2 3 4; do
    KEYS=$(SSH_AUTH_SOCK="$SOCKET_PATH" ssh-add -L 2>/dev/null)
    if [[ -n "$KEYS" ]]; then break; fi
    sleep 2
done

if [[ -n "$KEYS" ]]; then
    echo "      Agent is live — auto-configuring git signing..."
    SSH_AUTH_SOCK="$SOCKET_PATH" bash "$BIN_DIR/setup-git-signing.sh"
else
    echo "      Agent not ready yet (Proton Pass may be locked or starting up)."
    echo "      After unlocking, run:  setup-git-signing.sh"
fi

# ── Load wrapper into current shell (when sourced) ───────────────────────────
unset -f git 2>/dev/null || true
if [[ -f "$BIN_DIR/proton-git-wrapper.sh" ]]; then
    # shellcheck disable=SC1090
    source "$BIN_DIR/proton-git-wrapper.sh" 2>/dev/null && \
        echo "      git() wrapper loaded into current shell." || true
fi

# Set SSH_AUTH_SOCK in current shell
export SSH_AUTH_SOCK="$SOCKET_PATH"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ✅ Setup complete!                                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "How it works:"
echo "  • SSH_AUTH_SOCK → $SOCKET_PATH"
echo "  • Authenticate once:  proton-login  (or: pass-cli login --interactive)"
echo "  • git push / signed commits just work while session is active"
echo "  • Session auto-locks after 15min (configurable)"
echo ""

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "⚠️  You ran this as a script (not sourced)."
    echo "   Start a new terminal, or run:"
    echo "     source ~/.bashrc"
    echo ""
fi

echo "Quick test:"
echo "  ssh -T git@github.com          # test SSH connection"
echo "  proton-status                   # check agent status"
echo "  git commit --allow-empty -S -m 'test'  # test signing"
