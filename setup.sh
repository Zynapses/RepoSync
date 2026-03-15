#!/usr/bin/env bash
#
# setup.sh — Zero-to-synced in one file.
#
# Run this on any fresh machine. It will:
#   1. Install Homebrew (macOS) or apt dependencies (Linux) if needed
#   2. Install git, gh, and jq if missing
#   3. Configure git global identity if not set
#   4. Verify GitHub authentication
#   5. Download & install github-sync script
#   6. Write config (preserves existing) & install background service
#   7. Run the first sync
#
# Safe to re-run — preserves existing config and only restarts the
# background service if the plist/unit actually changed.
#
# Usage (on a brand new machine):
#   /bin/bash -c "$(curl -sL https://raw.githubusercontent.com/Zynapses/RepoSync/main/setup.sh)"
#
# Prerequisite: gh must be authenticated (Windsurf/Kiro handles this automatically).

set -euo pipefail

# ─── Config defaults ──────────────────────────────────────────────────────────
GH_USER="Zynapses"
REPO_NAME="RepoSync"
DEFAULT_GIT_NAME="Zynapses"
DEFAULT_GIT_EMAIL="bob.long@zynapses.ai"
RAW_BASE="https://raw.githubusercontent.com/${GH_USER}/${REPO_NAME}/main"
INSTALL_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/github-sync"
DATA_DIR="$HOME/.local/share/github-sync"
SYNC_INTERVAL=300  # 5 minutes
PLIST_LABEL="com.github-sync.agent"
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
echo "║     RepoSync — Full Machine Setup               ║"
echo "║     One script. Zero to synced.                 ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ─── 1. Package manager ──────────────────────────────────────────────────────
header "Step 1/7: Package manager"

if [[ "$OS" == "Darwin" ]]; then
    # Ensure brew is on PATH even if shell profile hasn't been sourced
    if ! command -v brew &>/dev/null; then
        for bp in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            if [[ -x "$bp" ]]; then
                eval "$("$bp" shellenv)"
                break
            fi
        done
    fi

    if command -v brew &>/dev/null; then
        success "Homebrew already installed"
    else
        info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        # Add brew to PATH for this session
        for bp in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            if [[ -x "$bp" ]]; then
                eval "$("$bp" shellenv)"
                break
            fi
        done
        command -v brew &>/dev/null || fail "Homebrew installed but not on PATH"
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

# ─── 5. Download & install github-sync ───────────────────────────────────────
header "Step 5/7: Install github-sync"

mkdir -p "$INSTALL_DIR"

# Try local copy first (running from cloned repo), then download via curl.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" 2>/dev/null && pwd 2>/dev/null)" || SCRIPT_DIR=""

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/github-sync.sh" ]]; then
    cp "$SCRIPT_DIR/github-sync.sh" "$INSTALL_DIR/github-sync"
    success "Installed from local repo: $SCRIPT_DIR"
else
    info "Downloading github-sync.sh from $RAW_BASE ..."
    if curl -fsSL "$RAW_BASE/github-sync.sh" -o "$INSTALL_DIR/github-sync"; then
        success "Downloaded github-sync.sh"
    else
        fail "Failed to download github-sync.sh from $RAW_BASE/github-sync.sh"
    fi
fi

chmod +x "$INSTALL_DIR/github-sync"

# Verify the file is non-empty
if [[ ! -s "$INSTALL_DIR/github-sync" ]]; then
    fail "github-sync script is empty after install — download may have failed"
fi

success "Installed to $INSTALL_DIR/github-sync ($(wc -c < "$INSTALL_DIR/github-sync" | tr -d ' ') bytes)"

# Ensure ~/.local/bin is in PATH (idempotent — only append once)
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    export PATH="$INSTALL_DIR:$PATH"

    SHELL_RC=""
    if [[ -f "$HOME/.zshrc" ]]; then
        SHELL_RC="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
        SHELL_RC="$HOME/.bashrc"
    elif [[ -f "$HOME/.profile" ]]; then
        SHELL_RC="$HOME/.profile"
    fi

    if [[ -n "$SHELL_RC" ]]; then
        # Only append if not already in the file
        if ! grep -qF "$INSTALL_DIR" "$SHELL_RC" 2>/dev/null; then
            echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$SHELL_RC"
            success "Added $INSTALL_DIR to PATH in $SHELL_RC"
        else
            success "$INSTALL_DIR already in $SHELL_RC"
        fi
    else
        warn "Add this to your shell profile: export PATH=\"$INSTALL_DIR:\$PATH\""
    fi
fi

# ─── 6. Write config & install background service ────────────────────────────
header "Step 6/7: Config & background service"

mkdir -p "$CONFIG_DIR" "$DATA_DIR"

GIT_NAME="$(git config --global user.name)"
GIT_EMAIL="$(git config --global user.email)"

# Preserve existing config — only write if missing
if [[ -f "$CONFIG_DIR/config" ]]; then
    success "Config already exists: $CONFIG_DIR/config (preserved)"
else
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
    success "Config written: $CONFIG_DIR/config"
fi

# Background service
if [[ "$OS" == "Darwin" ]]; then
    PLIST_DIR="$HOME/Library/LaunchAgents"
    PLIST_FILE="$PLIST_DIR/${PLIST_LABEL}.plist"
    mkdir -p "$PLIST_DIR"

    PLIST_CONTENT="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\"
  \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
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
</plist>"

    # Only reload if plist content changed or agent isn't loaded
    NEEDS_RELOAD=false
    if [[ ! -f "$PLIST_FILE" ]]; then
        NEEDS_RELOAD=true
    elif ! diff -q <(echo "$PLIST_CONTENT") "$PLIST_FILE" &>/dev/null; then
        NEEDS_RELOAD=true
    elif ! launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
        NEEDS_RELOAD=true
    fi

    if [[ "$NEEDS_RELOAD" == "true" ]]; then
        echo "$PLIST_CONTENT" > "$PLIST_FILE"
        launchctl unload "$PLIST_FILE" 2>/dev/null || true
        launchctl load "$PLIST_FILE"
        success "launchd agent installed: syncing every ${SYNC_INTERVAL}s, starts at login"
    else
        success "launchd agent already running — no changes needed"
    fi

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
