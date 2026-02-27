#!/bin/bash
# Proton Pass git auth gate
# Requires Proton Pass desktop app to be unlocked for push and signed commits.
# Source this file into your shell (e.g. add to ~/.bashrc):
#   source ~/.local/bin/proton-git-wrapper.sh

_proton_ensure_agent() {
    local sock="${SSH_AUTH_SOCK:-$HOME/.ssh/proton-pass-agent.sock}"

    # Check if the agent socket file exists at all
    if [[ ! -S "$sock" ]]; then
        echo "❌ Proton Pass SSH agent socket not found." >&2
        echo "   Check service:  systemctl --user status proton-pass-ssh-agent" >&2
        return 1
    fi

    # Ask the agent to list accessible keys.
    # When Proton Pass is locked (PIN screen), the agent socket is present
    # but returns NO keys — ssh-add -L will output nothing.
    # Only when the vault is actually unlocked are keys returned.
    local keys
    keys=$(SSH_AUTH_SOCK="$sock" ssh-add -L 2>/dev/null)
    if [[ -z "$keys" ]]; then
        echo "🔒 Proton Pass is locked. Unlock the Proton Pass desktop app and try again." >&2
        return 1
    fi

    export SSH_AUTH_SOCK="$sock"
    return 0
}

# Wrap git to gate push and signed commits behind Proton Pass desktop unlock
git() {
    case "$1" in
        push|push-*)
            _proton_ensure_agent || return 1
            ;;
        commit)
            # Check if signing is involved (-S flag or commit.gpgsign=true)
            if [[ "$*" == *"-S"* ]] || [[ "$(command git config --get commit.gpgsign 2>/dev/null)" == "true" ]]; then
                # Ensure signing is configured for SSH, not GPG
                local fmt
                fmt=$(command git config --get gpg.format 2>/dev/null)
                if [[ "$fmt" != "ssh" ]]; then
                    echo "❌ git SSH signing is not configured." >&2
                    echo "   Run: setup-git-signing.sh" >&2
                    return 1
                fi
                # Ensure a signing key is set
                local sigkey
                sigkey=$(command git config --get user.signingkey 2>/dev/null)
                if [[ -z "$sigkey" ]]; then
                    echo "❌ No SSH signing key configured." >&2
                    echo "   Run: setup-git-signing.sh" >&2
                    return 1
                fi
                _proton_ensure_agent || return 1
            fi
            ;;
        tag)
            # Check if signing is involved (-s flag or tag.gpgsign=true)
            if [[ "$*" == *"-s"* ]] || [[ "$(command git config --get tag.gpgsign 2>/dev/null)" == "true" ]]; then
                _proton_ensure_agent || return 1
            fi
            ;;
    esac
    command git "$@"
}
