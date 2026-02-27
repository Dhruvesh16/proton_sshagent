#!/bin/bash
# Supervised Proton Pass SSH Agent wrapper
# Waits for login, starts agent, restarts it if it dies

PASS_CLI="/usr/bin/pass-cli"
SOCKET_PATH="$HOME/.ssh/proton-pass-agent.sock"
CHECK_INTERVAL=20   # seconds to wait between login checks when not logged in
RESTART_DELAY=3     # seconds to wait before restarting a crashed agent

echo "[proton-agent] Starting supervisor..."

while true; do
    # Remove stale socket before each start attempt
    rm -f "$SOCKET_PATH"

    # Wait until pass-cli session is valid
    echo "[proton-agent] Checking Proton Pass login..."
    until "$PASS_CLI" info &>/dev/null; do
        echo "[proton-agent] Not logged in, retrying in ${CHECK_INTERVAL}s..."
        sleep "$CHECK_INTERVAL"
    done

    echo "[proton-agent] Login confirmed. Starting SSH agent on $SOCKET_PATH ..."

    # Run agent (not exec — so we can supervise and restart it)
    "$PASS_CLI" ssh-agent start --socket-path "$SOCKET_PATH"
    EXIT_CODE=$?

    echo "[proton-agent] SSH agent exited (code=$EXIT_CODE). Restarting in ${RESTART_DELAY}s..."
    sleep "$RESTART_DELAY"
done
