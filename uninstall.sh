#!/bin/bash
# uninstall.sh — Fully remove Proton Pass SSH Agent setup

set -e

echo "=== Proton Pass SSH Agent Uninstall ==="
echo ""

# Stop and disable systemd service
systemctl --user stop proton-pass-ssh-agent.service 2>/dev/null && echo "  Service stopped." || true
systemctl --user disable proton-pass-ssh-agent.service 2>/dev/null && echo "  Service disabled." || true
systemctl --user daemon-reload 2>/dev/null

# Kill any running agent process
pkill -f "pass-cli ssh-agent" 2>/dev/null && echo "  Agent process killed." || true

# Remove installed scripts
rm -f ~/.local/bin/proton-pass-ssh-agent-wrapper.sh
rm -f ~/.local/bin/proton-git-wrapper.sh
rm -f ~/.local/bin/setup-git-signing.sh
rm -f ~/.local/bin/proton-pin-setup
echo "  Scripts removed from ~/.local/bin/"

# Remove systemd service file
rm -f ~/.config/systemd/user/proton-pass-ssh-agent.service
echo "  Systemd service file removed."

# Remove socket and key files
rm -f ~/.ssh/proton-pass-agent.sock
rm -f ~/.ssh/proton-signing.pub
rm -f ~/.ssh/allowed_signers
echo "  SSH socket and key files removed."

# Remove ~/.ssh/config block
if grep -qF "proton-pass-agent.sock" ~/.ssh/config 2>/dev/null; then
    sed -i '/# Proton Pass SSH Agent/,/IdentityAgent.*proton-pass-agent\.sock/d' ~/.ssh/config
    echo "  Removed IdentityAgent block from ~/.ssh/config"
fi

# Remove lines added to ~/.bashrc
for entry in \
    "# Proton Pass SSH Agent socket" \
    "export SSH_AUTH_SOCK.*proton-pass-agent" \
    "# Proton Pass git auth gate" \
    "# Proton Pass git PIN gate" \
    "source.*proton-git-wrapper\.sh"; do
    sed -i "/$entry/d" ~/.bashrc 2>/dev/null || true
done

# Same for ~/.zshrc
if [ -f ~/.zshrc ]; then
    for entry in \
        "# Proton Pass SSH Agent socket" \
        "export SSH_AUTH_SOCK.*proton-pass-agent" \
        "# Proton Pass git auth gate" \
        "# Proton Pass git PIN gate" \
        "source.*proton-git-wrapper\.sh"; do
        sed -i "/$entry/d" ~/.zshrc 2>/dev/null || true
    done
fi

# Same for fish
if [ -f ~/.config/fish/config.fish ]; then
    for entry in \
        "# Proton Pass SSH Agent socket" \
        "set -gx SSH_AUTH_SOCK.*proton-pass-agent" \
        "# Proton Pass git auth gate" \
        "# Proton Pass git PIN gate" \
        "proton-git-wrapper"; do
        sed -i "/$entry/d" ~/.config/fish/config.fish 2>/dev/null || true
    done
fi
echo "  Shell config entries removed."

# Remove git global signing config
git config --global --unset gpg.format 2>/dev/null || true
git config --global --unset user.signingkey 2>/dev/null || true
git config --global --unset commit.gpgsign 2>/dev/null || true
git config --global --unset tag.gpgsign 2>/dev/null || true
git config --global --unset gpg.ssh.allowedsignersfile 2>/dev/null || true
echo "  Git global signing config removed."

# Remove PIN files
rm -f ~/.config/proton-pass-pin-hash
rm -f /tmp/.proton-pin-session-$(id -u)

echo ""
echo "=== Uninstall complete. ==="
echo "Reload your shell:  source ~/.bashrc"
