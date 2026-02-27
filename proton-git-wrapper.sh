#!/bin/bash
# Proton Pass PIN verification for git operations
# Source this file into your shell (e.g. add to ~/.bashrc):
#   source ~/.local/bin/proton-git-wrapper.sh

PROTON_PIN_HASH_FILE="$HOME/.config/proton-pass-pin-hash"
PROTON_PIN_SESSION_FILE="/tmp/.proton-pin-session-$(id -u)"
PROTON_PIN_SESSION_TTL=900  # 15 minutes — re-ask after this

_proton_verify_pin() {
    # If no PIN is set, skip verification
    if [ ! -f "$PROTON_PIN_HASH_FILE" ]; then
        return 0
    fi

    # Check if we have a valid session (PIN entered recently)
    if [ -f "$PROTON_PIN_SESSION_FILE" ]; then
        local last_auth
        last_auth=$(cat "$PROTON_PIN_SESSION_FILE" 2>/dev/null)
        local now
        now=$(date +%s)
        if [ -n "$last_auth" ] && [ $((now - last_auth)) -lt $PROTON_PIN_SESSION_TTL ]; then
            return 0
        fi
    fi

    # Prompt for PIN
    local stored_hash
    stored_hash=$(cat "$PROTON_PIN_HASH_FILE" 2>/dev/null)

    local attempts=0
    while [ $attempts -lt 3 ]; do
        read -s -p "🔐 Proton Pass PIN: " pin </dev/tty
        echo >/dev/tty

        local input_hash
        input_hash=$(echo -n "$pin" | sha256sum | cut -d' ' -f1)

        if [ "$input_hash" = "$stored_hash" ]; then
            # Save session timestamp
            date +%s > "$PROTON_PIN_SESSION_FILE"
            chmod 600 "$PROTON_PIN_SESSION_FILE"
            return 0
        fi

        attempts=$((attempts + 1))
        if [ $attempts -lt 3 ]; then
            echo "❌ Invalid PIN. $((3 - attempts)) attempt(s) remaining." >/dev/tty
        fi
    done

    echo "❌ Authentication failed." >&2
    return 1
}

# Wrap git to require PIN for push and signed commits
git() {
    case "$1" in
        push|push-*)
            _proton_verify_pin || return 1
            ;;
        commit)
            # Check if signing is involved (-S flag or commit.gpgsign=true)
            if [[ "$*" == *"-S"* ]] || [[ "$(command git config --get commit.gpgsign 2>/dev/null)" == "true" ]]; then
                _proton_verify_pin || return 1
            fi
            ;;
        tag)
            # Check if signing is involved (-s flag or tag.gpgsign=true)
            if [[ "$*" == *"-s"* ]] || [[ "$(command git config --get tag.gpgsign 2>/dev/null)" == "true" ]]; then
                _proton_verify_pin || return 1
            fi
            ;;
    esac
    command git "$@"
}

# Lock function — clear the session to require PIN again
proton-lock() {
    rm -f "$PROTON_PIN_SESSION_FILE"
    echo "🔒 Proton Pass PIN session locked. Next git push/sign will require PIN."
}
