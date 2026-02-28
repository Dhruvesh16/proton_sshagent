#!/bin/bash
# Proton Pass git integration — pass-cli native SSH agent
#
# Source this file into your shell (e.g. add to ~/.bashrc):
#   source ~/.local/bin/proton-git-wrapper.sh
#
# How it works:
#   - SSH_AUTH_SOCK points to the Proton Pass agent socket
#   - For operations requiring keys (push, signed commits/tags), the wrapper
#     verifies the agent is running and keys are available.
#   - If no session exists, triggers `pass-cli login --interactive` directly
#     in the terminal — no desktop app dependency.
#   - Session timeout mechanism kills the agent to purge cached keys.

# ── Configuration ─────────────────────────────────────────────────────────────
PROTON_SOCKET="${SSH_AUTH_SOCK:-$HOME/.ssh/proton-pass-agent.sock}"
PROTON_UNLOCK_TIMEOUT="${PROTON_UNLOCK_TIMEOUT:-60}"      # seconds to wait for unlock
PROTON_SESSION_TIMEOUT="${PROTON_SESSION_TIMEOUT:-900}"    # 15 min session
PROTON_SESSION_FILE="/tmp/.proton-session-$(id -u)"

# ── Session management (auto-lock after timeout) ───────────────────────────
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
    # pass-cli's agent caches keys forever, so we kill it on session expiry)
    _proton_kill_agent
    echo "" >&2
    echo "🔒 Proton Pass session expired (auto-lock after $(( PROTON_SESSION_TIMEOUT / 60 ))min)." >&2
    echo "   Authenticating via pass-cli..." >&2

    # Trigger pass-cli login if no active session
    if ! _proton_has_cli_session; then
        _proton_cli_login || return 1
    fi

    # Wait for the systemd service to detect the session and start the agent
    echo "   Waiting for SSH agent to start..." >&2
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

    echo "❌ Timed out waiting for SSH agent (${PROTON_UNLOCK_TIMEOUT}s)." >&2
    echo "   Try: proton-login   or   pass-cli login --interactive" >&2
    return 1
}

# ── Check if pass-cli has an active session ───────────────────────────────────
_proton_has_cli_session() {
    local cli
    cli=$(command -v pass-cli 2>/dev/null || echo "/usr/bin/pass-cli")
    "$cli" info &>/dev/null
}

# ── Trigger pass-cli login (interactive, in-terminal) ─────────────────────────
_proton_cli_login() {
    local cli
    cli=$(command -v pass-cli 2>/dev/null || echo "/usr/bin/pass-cli")
    echo "" >&2
    echo "🔑 Proton Pass login required." >&2
    echo "   Launching pass-cli login..." >&2
    echo "" >&2
    if "$cli" login --interactive; then
        echo "" >&2
        echo "✅ Login successful." >&2
        return 0
    else
        echo "" >&2
        echo "❌ Login failed or cancelled." >&2
        return 1
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
        push)
            # Push needs SSH keys for authentication
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

    # If no CLI session, trigger login first
    if ! _proton_has_cli_session; then
        _proton_cli_login || return 1
    fi

    echo "Waiting for SSH agent..." >&2

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

    echo "❌ Agent not available. Try: proton-login" >&2
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

# ── proton-login: authenticate with pass-cli and start session ────────────────
proton-login() {
    if _proton_has_cli_session; then
        echo "Already logged in." >&2
    else
        _proton_cli_login || return 1
    fi
    # Wait for agent to come up (systemd supervisor will detect the session)
    proton-unlock
}

# ── proton-logout: end pass-cli session and kill agent ────────────────────────
proton-logout() {
    _proton_session_invalidate
    _proton_kill_agent
    local cli
    cli=$(command -v pass-cli 2>/dev/null || echo "/usr/bin/pass-cli")
    "$cli" logout 2>/dev/null || true
    echo "🔒 Logged out. Session ended, agent keys purged." >&2
}
