#!/bin/bash
# Proton Pass SSH Agent — native agent supervisor
# Works like 1Password: auto-detects the desktop app's native socket,
# falls back to pass-cli if needed.
#
# The agent stays running as long as Proton Pass is open.
# No manual login required — the desktop app handles authentication.

set -euo pipefail

# ── Socket paths (checked in order, like 1Password's agent.sock) ─────────────
# Proton Pass desktop app native socket locations (varies by version/distro)
NATIVE_SOCKETS=(
    "${PROTON_PASS_AGENT_SOCK:-}"
    "$HOME/.proton/pass/ssh-agent.sock"
    "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/proton-pass/ssh-agent.sock"
    "$HOME/.proton-pass/ssh-agent.sock"
)

# Our managed socket (fallback when desktop app doesn't provide a native socket)
MANAGED_SOCKET="$HOME/.ssh/proton-pass-agent.sock"

# The canonical socket that SSH_AUTH_SOCK and IdentityAgent point to
CANONICAL_SOCKET="$HOME/.ssh/proton-pass-agent.sock"

# pass-cli binary (try PATH first, then common locations)
PASS_CLI="${PROTON_PASS_CLI:-}"
if [[ -z "$PASS_CLI" ]]; then
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
fi

CHECK_INTERVAL=5    # seconds between checks for native socket / login
RESTART_DELAY=3     # seconds before restarting a crashed CLI agent

log() { echo "[proton-agent] $*"; }

# ── Detect a live native socket from the Proton Pass desktop app ──────────────
find_native_socket() {
    for sock in "${NATIVE_SOCKETS[@]}"; do
        [[ -z "$sock" ]] && continue
        if [[ -S "$sock" ]]; then
            # Verify the socket actually responds
            if SSH_AUTH_SOCK="$sock" ssh-add -l &>/dev/null || \
               SSH_AUTH_SOCK="$sock" ssh-add -l 2>&1 | grep -q "no identities"; then
                echo "$sock"
                return 0
            fi
        fi
    done
    return 1
}

# ── Create a symlink from the canonical path to the real socket ───────────────
# This is the 1Password approach: one stable path that everything points to.
link_canonical() {
    local target="$1"
    if [[ "$target" == "$CANONICAL_SOCKET" ]]; then
        return 0
    fi
    rm -f "$CANONICAL_SOCKET"
    ln -sf "$target" "$CANONICAL_SOCKET"
    log "Linked $CANONICAL_SOCKET → $target"
}

# ── Main supervisor loop ─────────────────────────────────────────────────────
log "Starting Proton Pass SSH agent supervisor..."
log "Canonical socket: $CANONICAL_SOCKET"

while true; do
    # ── Strategy 1: Use the desktop app's native socket (like 1Password) ──────
    native="$(find_native_socket || true)"
    if [[ -n "$native" ]]; then
        log "Found native Proton Pass desktop socket: $native"
        link_canonical "$native"

        # Monitor the native socket — when it disappears, we retry
        while [[ -S "$native" ]]; do
            sleep "$CHECK_INTERVAL"
        done
        log "Native socket gone (app closed?). Will re-detect..."
        rm -f "$CANONICAL_SOCKET"
        sleep "$RESTART_DELAY"
        continue
    fi

    # ── Strategy 2: Start agent via pass-cli (fallback) ───────────────────────
    if [[ -z "$PASS_CLI" || ! -x "$PASS_CLI" ]]; then
        log "No native socket and pass-cli not found. Waiting ${CHECK_INTERVAL}s..."
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # Remove stale socket
    rm -f "$MANAGED_SOCKET"

    # Wait for pass-cli session to be valid (user logged in via desktop or CLI)
    log "No native socket. Waiting for Proton Pass login (via pass-cli)..."
    until "$PASS_CLI" info &>/dev/null; do
        # Re-check for native socket while waiting
        native="$(find_native_socket || true)"
        if [[ -n "$native" ]]; then
            continue 2  # jump back to outer loop
        fi
        sleep "$CHECK_INTERVAL"
    done

    log "Login confirmed. Starting SSH agent on $MANAGED_SOCKET ..."

    # Run agent (not exec, so we can supervise and restart)
    "$PASS_CLI" ssh-agent start --socket-path "$MANAGED_SOCKET" &
    AGENT_PID=$!

    # Wait a moment for the socket to appear
    for _ in 1 2 3 4 5; do
        [[ -S "$MANAGED_SOCKET" ]] && break
        sleep 1
    done

    if [[ -S "$MANAGED_SOCKET" ]]; then
        link_canonical "$MANAGED_SOCKET"
        log "Agent running (PID $AGENT_PID)."
    fi

    # Wait for agent to exit
    wait "$AGENT_PID" 2>/dev/null || true
    EXIT_CODE=$?

    log "Agent exited (code=$EXIT_CODE). Restarting in ${RESTART_DELAY}s..."
    rm -f "$MANAGED_SOCKET" "$CANONICAL_SOCKET"
    sleep "$RESTART_DELAY"
done
