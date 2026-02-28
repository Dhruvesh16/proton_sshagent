#!/bin/bash
# Proton Pass SSH Agent — pass-cli native supervisor
#
# Pure pass-cli authentication: no desktop app dependency.
# The user authenticates via `pass-cli login --interactive` (or web login),
# then this supervisor starts and manages the SSH agent.
#
# Flow:
#   1. Poll for an active pass-cli session (`pass-cli info`)
#   2. When session exists → start `pass-cli ssh-agent start`
#   3. Supervise the agent; restart if it crashes
#   4. If session expires → clean up and wait for re-login
#
# The git wrapper (proton-git-wrapper.sh) can trigger `pass-cli login`
# interactively when needed, so the user never has to think about it.

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SOCKET_PATH="$HOME/.ssh/proton-pass-agent.sock"
CHECK_INTERVAL=3    # seconds between session checks
RESTART_DELAY=2     # seconds before restarting a crashed agent

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

if [[ -z "$PASS_CLI" || ! -x "$PASS_CLI" ]]; then
    echo "[proton-agent] ERROR: pass-cli not found. Install from:" >&2
    echo "  https://github.com/ProtonPass/pass-cli-linux/releases" >&2
    exit 1
fi

log() { echo "[proton-agent] $(date '+%H:%M:%S') $*"; }

# ── Graceful shutdown (from proton-lock or systemd stop) ──────────────────────
AGENT_PID=""
cleanup() {
    log "Shutting down..."
    [[ -n "$AGENT_PID" ]] && kill "$AGENT_PID" 2>/dev/null || true
    rm -f "$SOCKET_PATH" 2>/dev/null
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── Check if pass-cli has an active session ───────────────────────────────────
has_session() {
    "$PASS_CLI" info &>/dev/null
}

# ── Main supervisor loop ─────────────────────────────────────────────────────
log "Starting Proton Pass SSH agent supervisor"
log "Socket: $SOCKET_PATH"
log "pass-cli: $PASS_CLI"

while true; do
    # ── Wait for an active pass-cli session ───────────────────────────────────
    if ! has_session; then
        log "No active session. Waiting for login... (run: pass-cli login --interactive)"
        while ! has_session; do
            sleep "$CHECK_INTERVAL"
        done
    fi

    log "Session active. Starting SSH agent..."
    rm -f "$SOCKET_PATH"

    # Start agent in background so we can supervise it
    "$PASS_CLI" ssh-agent start --socket-path "$SOCKET_PATH" &
    AGENT_PID=$!

    # Wait for socket to appear (up to 10s)
    for i in $(seq 1 10); do
        [[ -S "$SOCKET_PATH" ]] && break
        sleep 1
    done

    if [[ -S "$SOCKET_PATH" ]]; then
        log "Agent running (PID $AGENT_PID). Socket ready."
    else
        log "WARNING: Socket did not appear after 10s. Agent may have failed."
    fi

    # Supervise: wait for the agent process to exit
    wait "$AGENT_PID" 2>/dev/null || true
    EXIT_CODE=$?
    AGENT_PID=""

    rm -f "$SOCKET_PATH"
    log "Agent exited (code=$EXIT_CODE). Restarting in ${RESTART_DELAY}s..."
    sleep "$RESTART_DELAY"
done
