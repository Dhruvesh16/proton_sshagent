#!/bin/bash
# uninstall.sh — Fully remove Proton Pass native SSH Agent setup

set -e

echo "=== Proton Pass SSH Agent — Uninstall ==="
echo ""

# ── Stop and disable systemd service ─────────────────────────────────────────
systemctl --user stop proton-pass-ssh-agent.service 2>/dev/null && echo "  Service stopped." || true
systemctl --user disable proton-pass-ssh-agent.service 2>/dev/null && echo "  Service disabled." || true
systemctl --user daemon-reload 2>/dev/null

# Kill any running agent process
pkill -f "pass-cli ssh-agent" 2>/dev/null && echo "  Agent process killed." || true

# ── Remove installed scripts ─────────────────────────────────────────────────
rm -f ~/.local/bin/proton-pass-ssh-agent-wrapper.sh
rm -f ~/.local/bin/proton-git-wrapper.sh
rm -f ~/.local/bin/setup-git-signing.sh
rm -f ~/.local/bin/proton-pin-setup
echo "  Scripts removed from ~/.local/bin/"

# ── Remove systemd service file ──────────────────────────────────────────────
rm -f ~/.config/systemd/user/proton-pass-ssh-agent.service
echo "  Systemd service file removed."

# ── Remove socket, symlinks, and key files ────────────────────────────────────
rm -f ~/.ssh/proton-pass-agent.sock
rm -f ~/.ssh/proton-signing.pub
rm -f ~/.ssh/allowed_signers
echo "  SSH socket and key files removed."

# ── Remove ~/.ssh/config block ────────────────────────────────────────────────
if grep -qF "proton-pass-agent.sock" ~/.ssh/config 2>/dev/null; then
    # Remove both old and new style comment blocks
    sed -i '/# ── Proton Pass SSH Agent/,/IdentityAgent.*proton-pass-agent\.sock/d' ~/.ssh/config 2>/dev/null || true
    sed -i '/# Proton Pass SSH Agent/,/IdentityAgent.*proton-pass-agent\.sock/d' ~/.ssh/config 2>/dev/null || true
    echo "  Removed IdentityAgent block from ~/.ssh/config"
fi

# ── Clean shell rc files (bash, zsh) ─────────────────────────────────────────
for SHELL_RC in ~/.bashrc ~/.zshrc; do
    [[ -f "$SHELL_RC" ]] || continue
    for entry in \
        "# Proton Pass SSH Agent.*" \
        "# Proton Pass git integration.*" \
        "# Proton Pass git auth gate" \
        "# Proton Pass git PIN gate" \
        "export SSH_AUTH_SOCK.*proton-pass-agent" \
        "source.*proton-git-wrapper\.sh"; do
        sed -i "/$entry/d" "$SHELL_RC" 2>/dev/null || true
    done
done

# ── Clean fish config ────────────────────────────────────────────────────────
if [[ -f ~/.config/fish/config.fish ]]; then
    for entry in \
        "# Proton Pass SSH Agent.*" \
        "# Proton Pass git integration.*" \
        "# Proton Pass git auth gate" \
        "set -gx SSH_AUTH_SOCK.*proton-pass-agent" \
        "proton-git-wrapper"; do
        sed -i "/$entry/d" ~/.config/fish/config.fish 2>/dev/null || true
    done
fi
echo "  Shell config entries removed."

# ── Remove git global signing config ─────────────────────────────────────────
git config --global --unset gpg.format 2>/dev/null || true
git config --global --unset user.signingkey 2>/dev/null || true
git config --global --unset commit.gpgsign 2>/dev/null || true
git config --global --unset tag.gpgsign 2>/dev/null || true
git config --global --unset gpg.ssh.allowedSignersFile 2>/dev/null || true
git config --global --unset gpg.ssh.defaultKeyCommand 2>/dev/null || true
echo "  Git global signing config removed."

# ── Unset git() function from current shell ──────────────────────────────────
unset -f git 2>/dev/null && echo "  git() function unset." || true
unset -f proton-lock 2>/dev/null || true
unset -f proton-unlock 2>/dev/null || true
unset -f proton-status 2>/dev/null || true
unset -f _proton_ensure_agent 2>/dev/null || true
unset -f _proton_focus_app 2>/dev/null || true
unset -f _proton_needs_signing 2>/dev/null || true
unset -f _proton_session_valid 2>/dev/null || true
unset -f _proton_session_touch 2>/dev/null || true
unset -f _proton_session_invalidate 2>/dev/null || true
unset -f _proton_kill_agent 2>/dev/null || true

# ── Remove legacy PIN files and session files ─────────────────────────────────
rm -f ~/.config/proton-pass-pin-hash
rm -f "/tmp/.proton-pin-session-$(id -u)"
rm -f "/tmp/.proton-session-$(id -u)"
echo "  Legacy PIN files and session files removed."

echo ""
echo "=== Uninstall complete. ==="
echo "Reload your shell:  source ~/.bashrc"
