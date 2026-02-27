#!/bin/bash
# Proton Pass git integration — native SSH agent (1Password-style)
#
# Source this file into your shell (e.g. add to ~/.bashrc):
#   source ~/.local/bin/proton-git-wrapper.sh
#
# How it works (same model as 1Password):
#   - SSH_AUTH_SOCK points to the Proton Pass agent socket
#   - For operations requiring keys (push, signed commits/tags), the wrapper
#     checks if the agent has keys. If not, it brings the Proton Pass app
#     to the foreground so you can unlock it — just like 1Password.
#   - No separate PIN. Proton Pass's own biometric / master password is the gate.

PROTON_SOCKET="${SSH_AUTH_SOCK:-$HOME/.ssh/proton-pass-agent.sock}"
PROTON_UNLOCK_TIMEOUT="${PROTON_UNLOCK_TIMEOUT:-60}"

# ── Ensure the agent is alive and vault is unlocked ───────────────────────────
_proton_ensure_agent() {
    local sock="$PROTON_SOCKET"

    # 1. Check socket exists
    if [[ ! -S "$sock" ]]; then
        echo "❌ Proton Pass SSH agent socket not found at $sock" >&2
        echo "   Start the Proton Pass desktop app, or run:" >&2
        echo "   systemctl --user start proton-pass-ssh-agent" >&2
        return 1
    fi

    # 2. Check if keys are available (vault unlocked)
    local keys
    keys=$(SSH_AUTH_SOCK="$sock" ssh-add -L 2>/dev/null)

    if [[ -n "$keys" ]]; then
        export SSH_AUTH_SOCK="$sock"
        return 0
    fi

    # 3. Vault is locked — bring Proton Pass to front (like 1Password auto-prompt)
    echo "🔒 Proton Pass is locked. Unlock the app to continue..." >&2
    _proton_focus_app

    # 4. Poll for unlock (1Password waits up to 120s, we use configurable timeout)
    local waited=0
    while (( waited < PROTON_UNLOCK_TIMEOUT )); do
        sleep 1
        (( waited++ ))
        keys=$(SSH_AUTH_SOCK="$sock" ssh-add -L 2>/dev/null)
        if [[ -n "$keys" ]]; then
            echo "✅ Proton Pass unlocked." >&2
            export SSH_AUTH_SOCK="$sock"
            return 0
        fi
    done

    echo "❌ Timed out waiting for Proton Pass unlock (${PROTON_UNLOCK_TIMEOUT}s)." >&2
    return 1
}

# ── Focus the Proton Pass desktop app (multi-DE support) ──────────────────────
_proton_focus_app() {
    # Try multiple methods to bring the window to focus
    if command -v gdbus &>/dev/null; then
        # GNOME / GTK-based desktops
        gdbus call --session \
            --dest org.freedesktop.DBus \
            --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.ListNames 2>/dev/null | \
            grep -q "proton" && true
    fi

    if command -v wmctrl &>/dev/null; then
        wmctrl -a "Proton Pass" 2>/dev/null || true
    elif command -v xdotool &>/dev/null; then
        xdotool search --name "Proton Pass" windowactivate --sync 2>/dev/null || true
    elif command -v kdialog &>/dev/null; then
        # KDE — try to raise via D-Bus
        true
    fi

    # Wayland (wlr-based compositors)
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        # swaymsg or hyprctl if available
        if command -v swaymsg &>/dev/null; then
            swaymsg '[title="Proton Pass"] focus' 2>/dev/null || true
        elif command -v hyprctl &>/dev/null; then
            hyprctl dispatch focuswindow "title:Proton Pass" 2>/dev/null || true
        fi
    fi
}

# ── Check if a commit/tag operation involves signing ──────────────────────────
_proton_needs_signing() {
    local subcmd="$1"
    shift
    local args="$*"

    case "$subcmd" in
        commit)
            [[ "$args" == *"-S"* ]] && return 0
            [[ "$(command git config --get commit.gpgsign 2>/dev/null)" == "true" ]] && return 0
            ;;
        tag)
            [[ "$args" == *"-s"* ]] && return 0
            [[ "$(command git config --get tag.gpgsign 2>/dev/null)" == "true" ]] && return 0
            ;;
    esac
    return 1
}

# ── Transparent git wrapper (like 1Password — no PIN, just app unlock) ────────
git() {
    case "${1:-}" in
        push|fetch|pull|clone)
            # Network operations that need SSH keys
            _proton_ensure_agent || return 1
            ;;
        commit|tag)
            # Only gate if signing is involved
            if _proton_needs_signing "$@"; then
                _proton_ensure_agent || return 1
            fi
            ;;
    esac
    command git "$@"
}

# ── Manual lock helper (like 1Password CLI lock) ─────────────────────────────
proton-lock() {
    echo "🔒 Lock Proton Pass from the desktop app." >&2
    echo "   The next git push/sign will require unlock." >&2
}

# ── Status check ─────────────────────────────────────────────────────────────
proton-status() {
    local sock="${PROTON_SOCKET}"
    echo "=== Proton Pass SSH Agent Status ==="
    echo "Socket: $sock"

    if [[ ! -S "$sock" ]]; then
        echo "Status: ❌ Socket not found"
        return 1
    fi

    local keys
    keys=$(SSH_AUTH_SOCK="$sock" ssh-add -L 2>/dev/null)
    if [[ -n "$keys" ]]; then
        echo "Status: ✅ Unlocked"
        echo ""
        echo "Available keys:"
        echo "$keys" | while IFS= read -r key; do
            echo "  • ${key##* }"
        done
    else
        echo "Status: 🔒 Locked (unlock Proton Pass to use keys)"
    fi
}
