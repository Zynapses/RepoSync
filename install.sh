#!/usr/bin/env bash
#
# install.sh — Install github-sync to /usr/local/bin (or custom prefix)
#
# Usage:
#   ./install.sh                    # Install to /usr/local/bin
#   PREFIX=~/.local ./install.sh    # Install to ~/.local/bin
#   ./install.sh --uninstall        # Remove github-sync

set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

uninstall() {
    echo "Uninstalling github-sync..."

    if [[ -f "$BIN_DIR/github-sync" ]]; then
        rm -f "$BIN_DIR/github-sync"
        echo -e "${GREEN}✓ Removed $BIN_DIR/github-sync${NC}"
    else
        echo -e "${YELLOW}⚠ $BIN_DIR/github-sync not found${NC}"
    fi

    # Remove launchd agent if present (macOS)
    local plist="$HOME/Library/LaunchAgents/com.github-sync.agent.plist"
    if [[ -f "$plist" ]]; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        echo -e "${GREEN}✓ Removed launchd agent${NC}"
    fi

    # Remove systemd units if present (Linux)
    local unit_dir="$HOME/.config/systemd/user"
    if [[ -f "$unit_dir/github-sync.timer" ]]; then
        systemctl --user stop github-sync.timer 2>/dev/null || true
        systemctl --user disable github-sync.timer 2>/dev/null || true
        rm -f "$unit_dir/github-sync.service" "$unit_dir/github-sync.timer"
        systemctl --user daemon-reload 2>/dev/null || true
        echo -e "${GREEN}✓ Removed systemd units${NC}"
    fi

    echo ""
    echo "Note: Config (~/.config/github-sync/) and logs (~/.local/share/github-sync/) were kept."
    echo "Remove them manually if desired."
}

install() {
    echo ""
    echo "Installing github-sync..."
    echo ""

    # Check dependencies
    local ok=true
    for cmd in git gh jq; do
        if command -v "$cmd" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $cmd found"
        else
            echo -e "  ${RED}✗${NC} $cmd not found"
            ok=false
        fi
    done

    if [[ "$ok" == "false" ]]; then
        echo ""
        echo -e "${RED}Missing dependencies. Please install them first:${NC}"
        echo "  macOS:  brew install gh jq"
        echo "  Ubuntu: sudo apt install gh jq"
        echo "  Fedora: sudo dnf install gh jq"
        exit 1
    fi

    # Install the script
    mkdir -p "$BIN_DIR"
    cp "$SCRIPT_DIR/github-sync.sh" "$BIN_DIR/github-sync"
    chmod +x "$BIN_DIR/github-sync"

    echo ""
    echo -e "${GREEN}✓ Installed to $BIN_DIR/github-sync${NC}"

    # Check if bin dir is in PATH
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
        echo ""
        echo -e "${YELLOW}⚠ $BIN_DIR is not in your PATH.${NC}"
        echo "  Add this to your shell profile (~/.zshrc or ~/.bashrc):"
        echo "    export PATH=\"$BIN_DIR:\$PATH\""
    fi

    echo ""
    echo "Next steps:"
    echo "  1. Run:  github-sync --setup     (interactive configuration)"
    echo "  2. Run:  github-sync --dry-run   (preview what will happen)"
    echo "  3. Run:  github-sync             (sync everything)"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
    --uninstall)
        uninstall
        ;;
    *)
        install
        ;;
esac
