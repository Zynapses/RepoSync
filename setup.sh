#!/usr/bin/env bash
#
# setup.sh — Zero-to-synced in one file.
#
# Run this on any fresh machine. It will:
#   1. Install Homebrew (macOS) or apt dependencies (Linux) if needed
#   2. Install git, gh, and jq if missing
#   3. Configure git global identity if not set
#   4. Authenticate with GitHub (gh auth login) if not already
#   5. Clone this repo, install github-sync, write config
#   6. Set up background sync (launchd / systemd, every 5 min)
#   7. Run the first sync
#
# Usage (on a brand new machine):
#   /bin/bash -c "$(curl -sL https://raw.githubusercontent.com/Zynapses/github-sync/main/setup.sh)"
#
# Prerequisite: gh must be authenticated (Windsurf/Kiro handles this automatically).

set -euo pipefail

# ─── Config defaults ──────────────────────────────────────────────────────────
GH_USER="Zynapses"
DEFAULT_GIT_NAME="Zynapses"
DEFAULT_GIT_EMAIL="bob.long@zynapses.ai"
REPO_URL="https://github.com/${GH_USER}/github-sync.git"
INSTALL_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/github-sync"
DATA_DIR="$HOME/.local/share/github-sync"
SYNC_INTERVAL=300  # 5 minutes
# ──────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "${RED}✗ $*${NC}"; exit 1; }
header()  { echo -e "\n${BOLD}── $* ──${NC}\n"; }

OS="$(uname)"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║     github-sync — Full Machine Setup            ║"
echo "║     One script. Zero to synced.                 ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ─── 1. Package manager ──────────────────────────────────────────────────────
header "Step 1/7: Package manager"

if [[ "$OS" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
        success "Homebrew already installed"
    else
        info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        # Add brew to PATH for this session
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -f /usr/local/bin/brew ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        success "Homebrew installed"
    fi
    PKG_INSTALL="brew install"
elif [[ "$OS" == "Linux" ]]; then
    if command -v apt-get &>/dev/null; then
        PKG_INSTALL="sudo apt-get install -y"
        # Ensure gh repo is available
        if ! command -v gh &>/dev/null; then
            info "Adding GitHub CLI apt repository..."
            (type -p wget >/dev/null || sudo apt-get install -y wget) \
            && sudo mkdir -p -m 755 /etc/apt/keyrings \
            && out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            && cat "$out" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
            && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
            && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
            && sudo apt-get update -qq
        fi
    elif command -v dnf &>/dev/null; then
        PKG_INSTALL="sudo dnf install -y"
        if ! command -v gh &>/dev/null; then
            sudo dnf install -y 'dnf-command(config-manager)' 2>/dev/null || true
            sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null || true
        fi
    else
        fail "Unsupported Linux distro. Install git, gh, and jq manually, then re-run."
    fi
    success "Package manager ready"
else
    fail "Unsupported OS: $OS"
fi

# ─── 2. Install dependencies ─────────────────────────────────────────────────
header "Step 2/7: Dependencies (git, gh, jq)"

for cmd in git gh jq; do
    if command -v "$cmd" &>/dev/null; then
        success "$cmd already installed"
    else
        info "Installing $cmd..."
        $PKG_INSTALL "$cmd"
        if command -v "$cmd" &>/dev/null; then
            success "$cmd installed"
        else
            fail "Failed to install $cmd"
        fi
    fi
done

# ─── 3. Git identity ─────────────────────────────────────────────────────────
header "Step 3/7: Git identity"

current_name="$(git config --global user.name 2>/dev/null || echo "")"
current_email="$(git config --global user.email 2>/dev/null || echo "")"

if [[ -n "$current_name" && -n "$current_email" ]]; then
    success "Git identity: $current_name <$current_email>"
else
    info "Setting git global identity..."
    if [[ -z "$current_name" ]]; then
        git config --global user.name "$DEFAULT_GIT_NAME"
        info "Set user.name = $DEFAULT_GIT_NAME"
    fi
    if [[ -z "$current_email" ]]; then
        git config --global user.email "$DEFAULT_GIT_EMAIL"
        info "Set user.email = $DEFAULT_GIT_EMAIL"
    fi
    current_name="$(git config --global user.name)"
    current_email="$(git config --global user.email)"
    success "Git identity: $current_name <$current_email>"
fi

# ─── 4. GitHub authentication ────────────────────────────────────────────────
header "Step 4/7: GitHub authentication"

if gh auth status &>/dev/null; then
    logged_in_as="$(gh api user --jq '.login' 2>/dev/null || echo "unknown")"
    success "Already authenticated as: $logged_in_as"
else
    fail "gh is not authenticated. Run 'gh auth login' first, then re-run this script."
fi

# ─── 5. Install github-sync ──────────────────────────────────────────────────
header "Step 5/7: Install github-sync"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
CLEANUP_REPO=false

# Are we already inside the cloned repo?
if [[ -f "$SCRIPT_DIR/github-sync.sh" ]]; then
    REPO_DIR="$SCRIPT_DIR"
    success "Using local repo: $REPO_DIR"
else
    REPO_DIR="$(mktemp -d)"
    info "Cloning github-sync..."
    git clone --quiet "$REPO_URL" "$REPO_DIR"
    success "Cloned to temp directory"
    CLEANUP_REPO=true
fi

mkdir -p "$INSTALL_DIR"
cp "$REPO_DIR/github-sync.sh" "$INSTALL_DIR/github-sync"
chmod +x "$INSTALL_DIR/github-sync"
success "Installed to $INSTALL_DIR/github-sync"

# Ensure ~/.local/bin is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    SHELL_RC=""
    if [[ -f "$HOME/.zshrc" ]]; then
        SHELL_RC="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
        SHELL_RC="$HOME/.bashrc"
    elif [[ -f "$HOME/.profile" ]]; then
        SHELL_RC="$HOME/.profile"
    fi

    if [[ -n "$SHELL_RC" ]]; then
        echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$SHELL_RC"
        export PATH="$INSTALL_DIR:$PATH"
        success "Added $INSTALL_DIR to PATH in $SHELL_RC"
    else
        warn "Add this to your shell profile: export PATH=\"$INSTALL_DIR:\$PATH\""
        export PATH="$INSTALL_DIR:$PATH"
    fi
fi

# ─── 6. Write config & install background service ────────────────────────────
header "Step 6/7: Config & background service"

mkdir -p "$CONFIG_DIR" "$DATA_DIR"

GIT_NAME="$(git config --global user.name)"
GIT_EMAIL="$(git config --global user.email)"

cat > "$CONFIG_DIR/config" <<EOF
# github-sync configuration
# Generated by: setup.sh
# Date: $(date '+%Y-%m-%d %H:%M:%S')
# Machine: $(hostname)

GITHUB_SYNC_DIR="\$HOME/Projects"
GITHUB_SYNC_GIT_NAME="$GIT_NAME"
GITHUB_SYNC_GIT_EMAIL="$GIT_EMAIL"
GITHUB_SYNC_PROTOCOL="https"
GITHUB_SYNC_FORKS="false"
GITHUB_SYNC_ARCHIVED="false"
EOF

success "Config: $CONFIG_DIR/config"

# Background service
if [[ "$OS" == "Darwin" ]]; then
    PLIST_DIR="$HOME/Library/LaunchAgents"
    PLIST_FILE="$PLIST_DIR/com.github-sync.agent.plist"
    mkdir -p "$PLIST_DIR"

    cat > "$PLIST_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.github-sync.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/github-sync</string>
    </array>
    <key>StartInterval</key>
    <integer>${SYNC_INTERVAL}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${DATA_DIR}/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${DATA_DIR}/launchd-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${INSTALL_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLIST

    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    launchctl load "$PLIST_FILE"
    success "launchd agent: syncing every ${SYNC_INTERVAL}s, starts at login"

elif [[ "$OS" == "Linux" ]]; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"

    cat > "$UNIT_DIR/github-sync.service" <<SVC
[Unit]
Description=GitHub Sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/github-sync
Environment=PATH=${INSTALL_DIR}:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
SVC

    cat > "$UNIT_DIR/github-sync.timer" <<TMR
[Unit]
Description=Run GitHub Sync periodically

[Timer]
OnBootSec=60
OnUnitActiveSec=${SYNC_INTERVAL}s
Persistent=true

[Install]
WantedBy=timers.target
TMR

    systemctl --user daemon-reload
    systemctl --user enable --now github-sync.timer
    success "systemd timer: syncing every ${SYNC_INTERVAL}s"
fi

# ─── 7. First sync ───────────────────────────────────────────────────────────
header "Step 7/7: First sync"

"$INSTALL_DIR/github-sync"

# Cleanup
if [[ "$CLEANUP_REPO" == "true" ]]; then
    rm -rf "$REPO_DIR"
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║               ✓ Setup Complete!                 ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║                                                  ║"
echo "║  All repos synced to:  ~/Projects                ║"
echo "║  Background sync:      every 5 minutes           ║"
echo "║  Manual sync:          github-sync               ║"
echo "║  Check status:         github-sync --status      ║"
echo "║  View logs:            github-sync --verbose      ║"
echo "║                                                  ║"
echo "║  That's it. You're done. Just work normally      ║"
echo "║  and everything stays in sync automatically.     ║"
echo "║                                                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
