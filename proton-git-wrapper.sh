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

    # Ask the agent for keys. When vault is locked the agent returns nothing.
    local keys
    keys=$(SSH_AUTH_SOCK="$sock" ssh-add -L 2>/dev/null)

    if [[ -z "$keys" ]]; then
        echo "🔒 Proton Pass is locked — bringing app to front, waiting for you to unlock..." >&2

        # Focus the Proton Pass window so the PIN dialog appears on top
        if command -v wmctrl &>/dev/null; then
            wmctrl -a "Proton Pass" 2>/dev/null
        fi
        if command -v xdotool &>/dev/null; then
            xdotool search --name "Proton Pass" windowactivate --sync 2>/dev/null
        fi

        # Poll every second for up to 60 s (like 1Password)
        local waited=0
        while [[ $waited -lt 60 ]]; do
            sleep 1
            waited=$((waited + 1))
            keys=$(SSH_AUTH_SOCK="$sock" ssh-add -L 2>/dev/null)
            if [[ -n "$keys" ]]; then
                echo "✅ Proton Pass unlocked. Continuing..." >&2
                break
            fi
        done

        if [[ -z "$keys" ]]; then
            echo "❌ Timed out waiting for Proton Pass to unlock." >&2
            return 1
        fi
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
