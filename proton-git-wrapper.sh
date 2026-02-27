#!/bin/bash
# Proton Pass git integration — native SSH agent (1Password-style)
#
# Source this file into your shell (e.g. add to ~/.bashrc):
#   source ~/.local/bin/proton-git-wrapper.sh
#
# How it works:
#   - SSH_AUTH_SOCK points to the Proton Pass agent socket
#   - For operations requiring keys (push, signed commits/tags), the wrapper
#     verifies Proton Pass is unlocked via a session timeout mechanism.
#   - When the session expires, the agent is restarted (clearing cached keys)
#     and the user must unlock Proton Pass to continue.
#   - No separate PIN. Proton Pass's own master password / biometric is the gate.

# ── Configuration ─────────────────────────────────────────────────────────────
PROTON_SOCKET="${SSH_AUTH_SOCK:-$HOME/.ssh/proton-pass-agent.sock}"
PROTON_UNLOCK_TIMEOUT="${PROTON_UNLOCK_TIMEOUT:-60}"      # seconds to wait for unlock
PROTON_SESSION_TIMEOUT="${PROTON_SESSION_TIMEOUT:-900}"    # 15 min session (like 1Password auto-lock)
PROTON_SESSION_FILE="/tmp/.proton-session-$(id -u)"

# ── Session management (auto-lock after timeout, like 1Password / sudo) ───────
_proton_session_valid() {
    [[ -f "$PROTON_SESSION_FILE" ]] || return 1
    local ts now
    ts=$(cat "$PROTON_SESSION_FILE" 2>/dev/null) || return 1
    now=$(date +%s)
    (( now - ts < PROTON_SESSION_TIMEOUT ))
}

_proton_session_touch() {
    date +%s > "$PROTON_SESSION_FILE"
    chmod 600 "$PROTON_SESSION_FILE" 2>/dev/null
}

_proton_session_invalidate() {
    rm -f "$PROTON_SESSION_FILE"
}

# ── Kill the agent to purge cached keys from memory ───────────────────────────
_proton_kill_agent() {
    pkill -f "pass-cli ssh-agent" 2>/dev/null || true
    rm -f "$HOME/.ssh/proton-pass-agent.sock" 2>/dev/null || true
}

# ── Ensure the agent is alive, vault is unlocked, and session is valid ────────
_proton_ensure_agent() {
    local sock="$PROTON_SOCKET"

    # Fast path: session still valid AND socket exists AND keys available
    if _proton_session_valid && [[ -S "$sock" ]]; then
        local fast_keys
        fast_keys=$(SSH_AUTH_SOCK="$sock" ssh-add -L 2>/dev/null)
        if [[ -n "$fast_keys" ]]; then
            export SSH_AUTH_SOCK="$sock"
            return 0
        fi
    fi

    # ── Session expired or agent not responding ───────────────────────────────
    # Kill agent to purge any cached keys (this is the key security measure —
    # pass-cli's agent caches keys forever, unlike 1Password which stops
    # serving keys when the vault locks)
    _proton_kill_agent
    echo "" >&2
    echo "🔒 Proton Pass session expired (auto-lock after $(( PROTON_SESSION_TIMEOUT / 60 ))min)." >&2
    echo "   Unlock Proton Pass to continue..." >&2
    _proton_focus_app

    # Wait for the systemd service to restart the agent and keys to become available
    local waited=0
    while (( waited < PROTON_UNLOCK_TIMEOUT )); do
        sleep 1
        (( waited++ ))

        # After killing, the systemd supervisor restarts the agent.
        # pass-cli ssh-agent will only serve keys if the CLI session is valid.
        if [[ -S "$sock" ]]; then
            local keys
            keys=$(SSH_AUTH_SOCK="$sock" ssh-add -L 2>/dev/null)
            if [[ -n "$keys" ]]; then
                echo "✅ Proton Pass unlocked. Session started." >&2
                _proton_session_touch
                export SSH_AUTH_SOCK="$sock"
                return 0
            fi
        fi
    done

    echo "❌ Timed out waiting for Proton Pass (${PROTON_UNLOCK_TIMEOUT}s)." >&2
    echo "   Make sure Proton Pass is open and unlocked, then try again." >&2
    return 1
}

# ── Focus the Proton Pass desktop app (multi-DE support) ──────────────────────
_proton_focus_app() {
    # KDE Wayland
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *"KDE"* ]]; then
        if command -v qdbus &>/dev/null; then
            # Try to activate Proton Pass via KDE's D-Bus interface
            local wid
            wid=$(qdbus org.kde.KWin /KWin org.kde.KWin.getWindowInfo 2>/dev/null | grep -i "proton" || true)
        fi
    fi

    # X11 tools
    if command -v wmctrl &>/dev/null; then
        wmctrl -a "Proton Pass" 2>/dev/null || true
    elif command -v xdotool &>/dev/null; then
        xdotool search --name "Proton Pass" windowactivate --sync 2>/dev/null || true
    fi

    # Wayland (wlr-based compositors)
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
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

# ── Transparent git wrapper ──────────────────────────────────────────────────
git() {
    case "${1:-}" in
        push|fetch|pull|clone)
            # All network operations require verified session
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

# ── proton-lock: immediately invalidate session and kill agent ────────────────
proton-lock() {
    _proton_session_invalidate
    _proton_kill_agent
    echo "🔒 Session locked. Agent keys purged from memory." >&2
    echo "   Next git push/sign will require Proton Pass unlock." >&2
}

# ── proton-unlock: start a fresh session (verifies agent is alive) ────────────
proton-unlock() {
    local sock="$PROTON_SOCKET"
    echo "Checking Proton Pass agent..." >&2

    # Wait for agent to be available (systemd may need to restart it)
    local waited=0
    while (( waited < 15 )); do
        if [[ -S "$sock" ]]; then
            local keys
            keys=$(SSH_AUTH_SOCK="$sock" ssh-add -L 2>/dev/null)
            if [[ -n "$keys" ]]; then
                _proton_session_touch
                export SSH_AUTH_SOCK="$sock"
                echo "✅ Proton Pass session started (expires in $(( PROTON_SESSION_TIMEOUT / 60 ))min)." >&2
                return 0
            fi
        fi
        sleep 1
        (( waited++ ))
    done

    echo "❌ Agent not available. Make sure Proton Pass is open and unlocked." >&2
    return 1
}

# ── Status check ─────────────────────────────────────────────────────────────
proton-status() {
    local sock="$PROTON_SOCKET"
    echo "=== Proton Pass SSH Agent Status ==="
    echo "Socket: $sock"

    if [[ ! -S "$sock" ]]; then
        echo "Agent:   ❌ Socket not found"
        echo "Session: ❌ No active session"
        return 1
    fi

    local keys
    keys=$(SSH_AUTH_SOCK="$sock" ssh-add -L 2>/dev/null)
    if [[ -n "$keys" ]]; then
        echo "Agent:   ✅ Running (keys available)"
        echo ""
        echo "Available keys:"
        echo "$keys" | while IFS= read -r key; do
            echo "  • ${key##* }"
        done
    else
        echo "Agent:   🔒 No keys (vault may be locked)"
    fi

    echo ""
    if _proton_session_valid; then
        local ts now remaining
        ts=$(cat "$PROTON_SESSION_FILE" 2>/dev/null)
        now=$(date +%s)
        remaining=$(( PROTON_SESSION_TIMEOUT - (now - ts) ))
        echo "Session: ✅ Active (expires in $(( remaining / 60 ))m $(( remaining % 60 ))s)"
    else
        echo "Session: 🔒 Expired (next git push/sign will require unlock)"
    fi
    echo "Timeout: ${PROTON_SESSION_TIMEOUT}s (set PROTON_SESSION_TIMEOUT to change)"
}
