# RepoSync

Keep all your GitHub repos in sync across multiple computers automatically. One command sets up everything — clones new repos, pulls updates, pushes local commits, and runs in the background.

> Formerly `github-sync`. Now maintained as a standalone project.

---

## Quick Start

### Prerequisites

The setup script installs these automatically, but if you want to do it yourself:

| Component | What it is | macOS | Ubuntu/Debian | Fedora |
|-----------|-----------|-------|---------------|--------|
| **git** | Version control | Pre-installed | `sudo apt install git` | `sudo dnf install git` |
| **gh** | GitHub CLI — authenticates and talks to GitHub | `brew install gh` | `sudo apt install gh` | `sudo dnf install gh` |
| **jq** | JSON processor — parses GitHub API responses | `brew install jq` | `sudo apt install jq` | `sudo dnf install jq` |
| **Homebrew** | Package manager (macOS only) | [brew.sh](https://brew.sh) | n/a | n/a |

> **Note:** `gh` must be authenticated. If you're using Windsurf or Kiro, this is already done for you. Otherwise run `gh auth login` first.

### Install (one command)

Open a terminal on any machine and run:

```bash
/bin/bash -c "$(curl -sL https://raw.githubusercontent.com/Zynapses/RepoSync/main/setup.sh)"
```

### What that command does

1. **Installs Homebrew** if on macOS and not already installed
2. **Installs git, gh, and jq** if any are missing
3. **Configures git identity** (`user.name` and `user.email`) if not already set
4. **Verifies GitHub authentication** via `gh auth status`
5. **Installs `github-sync`** to `~/.local/bin` (adds to PATH if needed)
6. **Writes config** to `~/.config/github-sync/config`
7. **Starts a background service** that syncs every 5 minutes:
   - **macOS** → launchd agent (runs at login)
   - **Linux** → systemd timer
8. **Runs the first sync** — clones all your GitHub repos to `~/Projects`

After that, every 5 minutes in the background it will:
- Pull new changes from GitHub on all repos
- Push any local commits you've made
- Clone any new repos you've created from another machine

### What gets installed where

| What | Location |
|------|----------|
| Sync script | `~/.local/bin/github-sync` |
| Config file | `~/.config/github-sync/config` |
| Sync log | `~/.local/share/github-sync/sync.log` |
| Service log (stdout) | `~/.local/share/github-sync/launchd-stdout.log` |
| Service log (stderr) | `~/.local/share/github-sync/launchd-stderr.log` |
| Background service (macOS) | `~/Library/LaunchAgents/com.github-sync.agent.plist` |
| Background service (Linux) | `~/.config/systemd/user/github-sync.service` and `.timer` |
| Your repos | `~/Projects/<repo-name>/` |

---

## Usage

After install, you can run these anytime:

```bash
github-sync                  # Sync all repos right now
github-sync --status         # Show status of every local repo
github-sync --dry-run        # Preview what would happen (no changes)
github-sync --verbose        # Sync with detailed output
github-sync --help           # Show all options
```

---

## Uninstall

To completely remove github-sync from a machine:

### 1. Stop and remove the background service

**macOS:**
```bash
launchctl unload ~/Library/LaunchAgents/com.github-sync.agent.plist
rm ~/Library/LaunchAgents/com.github-sync.agent.plist
```

**Linux:**
```bash
systemctl --user stop github-sync.timer
systemctl --user disable github-sync.timer
rm ~/.config/systemd/user/github-sync.service
rm ~/.config/systemd/user/github-sync.timer
systemctl --user daemon-reload
```

### 2. Remove the script

```bash
rm ~/.local/bin/github-sync
```

### 3. Remove config and logs

```bash
rm -rf ~/.config/github-sync
rm -rf ~/.local/share/github-sync
```

Your repos in `~/Projects/` are **not touched** — they're normal git repos you can keep using.

---

## Conflict Handling

- **Dirty working tree** — Auto-stashed before pull, restored after
- **Rebase conflicts** — Automatically aborted (your local state is preserved)
- **Stash conflicts** — Changes remain in stash for you to resolve manually

---

## License

MIT
