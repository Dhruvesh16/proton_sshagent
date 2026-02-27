# Proton Pass — Native SSH Agent for Linux

Use **Proton Pass** as a native SSH agent on Linux, the same way [1Password SSH Agent](https://developer.1password.com/docs/ssh/) works:

- **One socket** → set `SSH_AUTH_SOCK` → SSH and git signing just work
- **No separate PIN** → Proton Pass's own biometric / master password is the gate
- **Automatic unlock prompts** → when keys are needed, the app is brought to focus
- **Session auto-lock** → keys are purged from memory after 15 min of inactivity (like 1Password / sudo)
- **Desktop-first** → auto-detects Proton Pass desktop app's native socket; falls back to `pass-cli`

## How it compares to 1Password

| Feature | 1Password | This project (Proton Pass) |
|---|---|---|
| Socket path | `~/.1password/agent.sock` | `~/.ssh/proton-pass-agent.sock` |
| Auth mechanism | App biometric / master password | App master password / biometric |
| Extra PIN required | No | No |
| Auto-lock | Configurable timeout | 15 min session timeout (configurable) |
| Git commit signing | Automatic via SSH agent | Automatic via SSH agent |
| Desktop app integration | Native | Native + pass-cli fallback |
| Systemd service | Not needed (app manages) | Supervisor for reliability |

## Quick start

```bash
# 1. Clone
git clone https://github.com/dhruvesh16/proton_sshagent.git ~/proton
cd ~/proton

# 2. Install (one command)
source ./setup.sh

# 3. Test
ssh -T git@github.com
proton-status
```

That's it. SSH and git signing work automatically whenever Proton Pass is unlocked.

## What's included

| File | Purpose |
|---|---|
| `setup.sh` | One-shot installer — sets up everything |
| `proton-pass-ssh-agent-wrapper.sh` | Agent supervisor — auto-detects desktop socket, falls back to pass-cli |
| `proton-pass-ssh-agent.service` | Systemd user service — keeps the agent running |
| `proton-git-wrapper.sh` | Transparent git wrapper — prompts for Proton Pass unlock on push/sign, enforces session timeout |
| `setup-git-signing.sh` | One-time git signing configuration |
| `uninstall.sh` | Clean removal of everything |

## Requirements

- **Proton Pass desktop app** (recommended) — provides native SSH agent socket
- OR **pass-cli** — [download from GitHub](https://github.com/ProtonPass/pass-cli-linux/releases)
- Linux with `systemd` (user session)
- `bash` 4+

## How it works

### Native Socket Detection (like 1Password)

The agent supervisor checks these locations for a native Proton Pass socket:

1. `$PROTON_PASS_AGENT_SOCK` (custom override)
2. `~/.proton/pass/ssh-agent.sock`
3. `$XDG_RUNTIME_DIR/proton-pass/ssh-agent.sock`
4. `~/.proton-pass/ssh-agent.sock`

If found, it symlinks to `~/.ssh/proton-pass-agent.sock` (the canonical path that `SSH_AUTH_SOCK` points to). If no native socket is found, it falls back to starting the agent via `pass-cli ssh-agent start`.

### Transparent Git Integration

The `git()` shell wrapper (sourced in `~/.bashrc`) intercepts:

- **`git push`**, **`git fetch`**, **`git pull`**, **`git clone`** → ensures agent is alive
- **`git commit -S`** or `commit.gpgsign=true` → ensures agent is alive for signing
- **`git tag -s`** or `tag.gpgsign=true` → ensures agent is alive for signing

When the vault is locked, the wrapper:
1. Brings the Proton Pass window to focus (Wayland + X11 support)
2. Waits up to 60 seconds (configurable via `PROTON_UNLOCK_TIMEOUT`)
3. Continues the git operation once unlocked

No separate PIN. No extra credentials. Just unlock Proton Pass.

### Session Auto-Lock (Security)

> **Why this matters:** Proton Pass's `pass-cli ssh-agent` caches keys in memory
> independently from the desktop app's lock state. Unlike 1Password (whose agent
> is part of the desktop app), `pass-cli`'s agent will serve keys even when the
> desktop app shows "Enter your PIN". This project fixes that gap.

The git wrapper enforces a **session timeout** (like `sudo` or 1Password's auto-lock):

1. After **15 minutes of inactivity** (configurable via `PROTON_SESSION_TIMEOUT`), the session expires
2. When expired, the wrapper **kills the SSH agent** — purging all cached keys from memory
3. The systemd service **automatically restarts** the agent
4. The user must **unlock Proton Pass** before the next git push/sign operation

This ensures that a locked desktop app actually prevents git operations.

### Shell Helpers

```bash
proton-status    # Show agent status, session expiry countdown, available keys
proton-lock      # Immediately lock: kills agent, purges keys, invalidates session
proton-unlock    # Start a fresh session (verifies agent is alive and has keys)
```

## Git commit signing

After setup, run once (if not auto-configured):

```bash
setup-git-signing.sh
```

This saves your signing key and enables `commit.gpgsign` and `tag.gpgsign` globally — just like 1Password's git signing setup.

```bash
# Verify
git commit --allow-empty -m "test signing" -S
git log --show-signature -1
```

## Configuration

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `SSH_AUTH_SOCK` | `~/.ssh/proton-pass-agent.sock` | Socket path for SSH and git |
| `PROTON_PASS_AGENT_SOCK` | (none) | Override native socket detection |
| `PROTON_PASS_CLI` | auto-detected | Path to pass-cli binary |
| `PROTON_UNLOCK_TIMEOUT` | `60` | Seconds to wait for vault unlock |
| `PROTON_SESSION_TIMEOUT` | `900` | Session auto-lock timeout in seconds (15 min) |

### Per-host SSH config

Like 1Password, you can restrict which hosts use Proton Pass:

```ssh-config
# Use Proton Pass for GitHub only
Host github.com
    IdentityAgent ~/.ssh/proton-pass-agent.sock

# Use default agent for everything else
Host *
    # (system default)
```

## Service management

```bash
systemctl --user status proton-pass-ssh-agent   # Status
systemctl --user restart proton-pass-ssh-agent   # Restart
journalctl --user -u proton-pass-ssh-agent -f    # Logs
```

## Uninstall

```bash
bash ./uninstall.sh
source ~/.bashrc
```

## Fish shell

Fish support is included. For the git wrapper, use [bass](https://github.com/edc/bass):

```fish
# In ~/.config/fish/config.fish
bass source ~/.local/bin/proton-git-wrapper.sh
```

## License

MIT
