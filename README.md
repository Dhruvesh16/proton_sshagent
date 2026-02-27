# proton-ssh-agent

Portable setup for using **Proton Pass** as an SSH agent on Linux, with a PIN-gated git wrapper for push and signed commits.

## What's included

| File | Purpose |
|---|---|
| `proton-pass-ssh-agent.service` | systemd user unit — keeps the SSH agent running in the background |
| `proton-pass-ssh-agent-wrapper.sh` | Supervisor loop — waits for Proton Pass login, then starts/restarts the agent |
| `proton-git-wrapper.sh` | Shell function that wraps `git` and prompts for a PIN before `push` or signed `commit`/`tag` |
| `proton-pin-setup` | Interactive script to set (or update) your git PIN |
| `setup-git-signing.sh` | Post-login script — reads your key from the agent and configures `git` SSH commit signing |
| `setup.sh` | One-shot installer — run this on a fresh machine |

## Requirements

- `pass-cli` installed to `~/.local/bin/pass-cli`
  Download from [Proton Pass CLI releases](https://github.com/ProtonPass/pass-cli-linux/releases) or via the Proton Pass desktop app.
- `systemd` (user session)
- `bash` 4+

## Quick start

```bash
# 1. Clone the repo
git clone https://github.com/dhruvesh16/prtoton_sshagent.git ~/proton
cd ~/proton

# 2. Run the installer
chmod +x setup.sh
./setup.sh

# 3. Reload your shell
source ~/.bashrc          # bash/zsh
# source ~/.config/fish/config.fish   # fish

# 4. Log into Proton Pass
pass-cli login

# 5. Configure git SSH signing
setup-git-signing.sh

# 6. Test SSH key via Proton
ssh -T git@github.com
```

> **Fish shell users:** `proton-git-wrapper.sh` is a bash script sourced into bash/zsh.
> For fish, use [bass](https://github.com/edc/bass) or call `bash -c 'source ~/.local/bin/proton-git-wrapper.sh && git "$@"' -- "$@"` as a fish function.

## How it works

### SSH Agent (`proton-pass-ssh-agent-wrapper.sh`)

The wrapper script runs in an infinite loop:

1. Removes any stale socket at `~/.ssh/proton-pass-agent.sock`
2. Polls `pass-cli info` every 20 seconds until you're logged in
3. Starts `pass-cli ssh-agent start --socket-path ...`
4. If the agent crashes, waits 3 seconds and restarts it

The systemd service (installed to `~/.config/systemd/user/`) ensures this supervisor starts on login and restarts if it ever exits.

### git PIN gate (`proton-git-wrapper.sh`)

Sourced into your `~/.bashrc`, this wraps the `git` command:

- **`git push`** — always requires PIN
- **`git commit -S`** or `commit.gpgsign=true` — requires PIN
- **`git tag -s`** or `tag.gpgsign=true` — requires PIN

A session token is cached to `/tmp/.proton-pin-session-<uid>` for **15 minutes**, so you won't be re-prompted repeatedly during a working session.

```bash
# Lock the session manually (forces PIN on next push)
proton-lock
```

### PIN setup (`proton-pin-setup`)

Hashes your PIN with SHA-256 and stores it at `~/.config/proton-pass-pin-hash` (mode 600). Run `proton-pin-setup` any time to change the PIN.

## Manual install (without `setup.sh`)

```bash
# Copy scripts
cp proton-pass-ssh-agent-wrapper.sh  ~/.local/bin/
cp proton-git-wrapper.sh             ~/.local/bin/
cp proton-pin-setup                  ~/.local/bin/
cp setup-git-signing.sh             ~/.local/bin/
chmod +x ~/.local/bin/proton-pass-ssh-agent-wrapper.sh \
         ~/.local/bin/proton-git-wrapper.sh \
         ~/.local/bin/proton-pin-setup \
         ~/.local/bin/setup-git-signing.sh

# Install service
cp proton-pass-ssh-agent.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now proton-pass-ssh-agent.service

# Configure SSH to use Proton socket as default IdentityAgent
cat >> ~/.ssh/config <<'EOF'

# Proton Pass SSH Agent
Host *
    IdentityAgent ~/.ssh/proton-pass-agent.sock
EOF

# Add to ~/.bashrc (or ~/.config/fish/config.fish for fish)
echo 'export SSH_AUTH_SOCK="$HOME/.ssh/proton-pass-agent.sock"' >> ~/.bashrc
echo 'source "$HOME/.local/bin/proton-git-wrapper.sh"'          >> ~/.bashrc

# Set PIN
proton-pin-setup

source ~/.bashrc

# After logging in with pass-cli login:
setup-git-signing.sh
```

## Git commit signing

After logging in with `pass-cli login`, run:

```bash
setup-git-signing.sh
```

This will:

1. List the SSH keys available in the Proton Pass agent
2. Let you choose which key to use for signing
3. Save the public key to `~/.ssh/proton-signing.pub`
4. Set `git config --global gpg.format ssh`
5. Set `git config --global user.signingkey ~/.ssh/proton-signing.pub`
6. Enable `commit.gpgsign true` and `tag.gpgsign true`
7. Add your key to `~/.ssh/allowed_signers`

To verify signing works:

```bash
git commit --allow-empty -m "test signing" -S
git log --show-signature -1
```

> The git signing inherits `SSH_AUTH_SOCK` from your environment. As long as `setup.sh` ran correctly and you reloaded your shell, commits will be signed automatically.

## Service management

```bash
# Status
systemctl --user status proton-pass-ssh-agent

# Restart
systemctl --user restart proton-pass-ssh-agent

# View logs
journalctl --user -u proton-pass-ssh-agent -f

# Disable
systemctl --user disable --now proton-pass-ssh-agent
```

## Uninstall

```bash
systemctl --user disable --now proton-pass-ssh-agent
rm ~/.config/systemd/user/proton-pass-ssh-agent.service
rm ~/.local/bin/proton-pass-ssh-agent-wrapper.sh
rm ~/.local/bin/proton-git-wrapper.sh
rm ~/.local/bin/proton-pin-setup
rm ~/.local/bin/setup-git-signing.sh
rm -f ~/.config/proton-pass-pin-hash
rm -f ~/.ssh/proton-signing.pub
# Remove lines added to ~/.bashrc / ~/.config/fish/config.fish manually
# Remove the IdentityAgent block from ~/.ssh/config manually
```

## License

MIT
