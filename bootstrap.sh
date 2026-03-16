#!/usr/bin/env bash
#
# bootstrap.sh — Lightweight bootstrap for RepoSync on a machine
# that already has git, gh, and jq installed.
#
# What it does:
#   1. Checks prerequisites (git, gh, jq)
#   2. Verifies GitHub CLI authentication
#   3. Downloads & installs github-sync to ~/.local/bin
#   4. Writes config from your git global identity (preserves existing)
#   5. Installs a background service (launchd on macOS, systemd on Linux)
#   6. Runs the first sync immediately
#
# Safe to re-run — preserves existing config and only restarts the
# background service if the plist/unit actually changed.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/Zynapses/RepoSync/main/bootstrap.sh | bash
#   # — or —
#   git clone https://github.com/Zynapses/RepoSync.git && cd RepoSync && ./bootstrap.sh

set -euo pipefail

REPO_OWNER="Zynapses"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/RepoSync/main"
INSTALL_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/github-sync"
DATA_DIR="$HOME/.local/share/github-sync"
SYNC_INTERVAL=300  # 5 minutes
PLIST_LABEL="com.github-sync.agent"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "${RED}✗${NC} $*"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║        RepoSync — One-Step Bootstrap            ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ─── 1. Check prerequisites ──────────────────────────────────────────────────
info "Checking prerequisites..."
missing=false

for cmd in git jq; do
    if command -v "$cmd" &>/dev/null; then
        success "$cmd found"
    else
        echo -e "${RED}✗${NC} $cmd not found"
        missing=true
    fi
done

if command -v gh &>/dev/null; then
    success "gh found ($(gh --version | head -1))"
else
    echo -e "${RED}✗${NC} gh (GitHub CLI) not found"
    missing=true
fi

if [[ "$missing" == "true" ]]; then
    echo ""
    echo "Install missing tools:"
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "  brew install gh jq"
    else
        echo "  sudo apt install gh jq   # Debian/Ubuntu"
        echo "  sudo dnf install gh jq   # Fedora"
    fi
    fail "Please install missing dependencies and re-run."
fi

# ─── 2. Check GitHub auth ────────────────────────────────────────────────────
echo ""
info "Checking GitHub authentication..."
if gh auth status &>/dev/null; then
    GH_USER="$(gh api user --jq '.login' 2>/dev/null || echo "unknown")"
    success "Authenticated as: $GH_USER"
else
    fail "Not authenticated. Run 'gh auth login' first, then re-run this script."
fi

# ─── 3. Download & install github-sync ───────────────────────────────────────
echo ""
info "Installing github-sync..."
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

# Ensure ~/.local/bin is in PATH (idempotent)
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    export PATH="$INSTALL_DIR:$PATH"

    SHELL_RC=""
    if [[ -f "$HOME/.zshrc" ]]; then
        SHELL_RC="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
        SHELL_RC="$HOME/.bashrc"
    fi

    if [[ -n "$SHELL_RC" ]]; then
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

# ─── 4. Write config ─────────────────────────────────────────────────────────
echo ""
mkdir -p "$CONFIG_DIR" "$DATA_DIR"

GIT_NAME="$(git config --global user.name 2>/dev/null || echo "")"
GIT_EMAIL="$(git config --global user.email 2>/dev/null || echo "")"

if [[ -z "$GIT_NAME" || -z "$GIT_EMAIL" ]]; then
    fail "Git global user.name or user.email not set. Run:
  git config --global user.name \"Your Name\"
  git config --global user.email \"you@example.com\"
Then re-run this script."
fi

# Preserve existing config — only write if missing
if [[ -f "$CONFIG_DIR/config" ]]; then
    success "Config already exists: $CONFIG_DIR/config (preserved)"
else
    cat > "$CONFIG_DIR/config" <<EOF
# github-sync configuration
# Generated by: bootstrap.sh
# Date: $(date '+%Y-%m-%d %H:%M:%S')
# Machine: $(hostname)

GITHUB_SYNC_DIR="\$HOME/Projects"
GITHUB_SYNC_GIT_NAME="$GIT_NAME"
GITHUB_SYNC_GIT_EMAIL="$GIT_EMAIL"
GITHUB_SYNC_PROTOCOL="https"
GITHUB_SYNC_FORKS="false"
GITHUB_SYNC_ARCHIVED="false"
GITHUB_SYNC_OWNER="$REPO_OWNER"
EOF
    success "Config written: $CONFIG_DIR/config"
fi

success "Identity: $GIT_NAME <$GIT_EMAIL>"

# ─── 5. Install background service ───────────────────────────────────────────
echo ""
info "Installing background service (every ${SYNC_INTERVAL}s)..."

if [[ "$(uname)" == "Darwin" ]]; then
    # macOS — launchd
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

elif [[ "$(uname)" == "Linux" ]]; then
    # Linux — systemd
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
    success "systemd timer installed: syncing every ${SYNC_INTERVAL}s"
else
    warn "Unknown OS — skipping background service. Use: github-sync --loop $SYNC_INTERVAL"
fi

# ─── 6. Run first sync ───────────────────────────────────────────────────────
echo ""
info "Running first sync..."
echo ""
"$INSTALL_DIR/github-sync"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║            ✓ Bootstrap Complete!                ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Repos synced to:  ~/Projects                   ║"
echo "║  Syncing every:    5 minutes (background)       ║"
echo "║  Manual sync:      github-sync                  ║"
echo "║  Check status:     github-sync --status         ║"
echo "║  View logs:        cat ~/.local/share/           ║"
echo "║                    github-sync/sync.log          ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
