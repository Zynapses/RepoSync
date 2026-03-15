#!/usr/bin/env bash
#
# github-sync — Query GitHub for all your repos, clone missing ones,
# verify git config, pull latest, and push local commits.
#
# Usage:
#   github-sync              # Run once
#   github-sync --loop 300   # Run continuously every 300 seconds (5 min)
#   github-sync --dry-run    # Show what would happen without making changes
#
# Prerequisites: gh (GitHub CLI) authenticated, git installed.

set -euo pipefail

# ─── Load config ──────────────────────────────────────────────────────────────
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/github-sync"
CONFIG_FILE="$CONFIG_DIR/config"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# ─── Configuration (config file > env vars > defaults) ────────────────────────
PROJECTS_DIR="${GITHUB_SYNC_DIR:-$HOME/Projects}"
GIT_USER_NAME="${GITHUB_SYNC_GIT_NAME:-}"
GIT_USER_EMAIL="${GITHUB_SYNC_GIT_EMAIL:-}"
CLONE_PROTOCOL="${GITHUB_SYNC_PROTOCOL:-https}"  # "https" or "ssh"
LOG_FILE="${GITHUB_SYNC_LOG:-$HOME/.local/share/github-sync/sync.log}"
INCLUDE_FORKS="${GITHUB_SYNC_FORKS:-false}"       # "true" to include forks
INCLUDE_ARCHIVED="${GITHUB_SYNC_ARCHIVED:-false}"  # "true" to include archived repos
# ──────────────────────────────────────────────────────────────────────────────

DRY_RUN=false
LOOP_INTERVAL=0
VERBOSE=false

# Colors (disabled when not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

usage() {
    cat <<EOF
Usage: github-sync [OPTIONS]

Sync all your GitHub repos to a local directory. Clones new repos,
pulls updates, pushes local commits, and ensures git config is correct.

Options:
  --loop <seconds>   Run continuously with the given interval
  --dry-run          Show what would happen without making changes
  --verbose          Show detailed output
  --dir <path>       Override projects directory
  --setup            Run interactive first-time setup
  --status           Show sync status of all repos
  --help             Show this help message

Config file: ~/.config/github-sync/config
Log file:    ~/.local/share/github-sync/sync.log

EOF
}

log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="[$timestamp] [$level] $*"

    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$msg" >> "$LOG_FILE"

    case "$level" in
        ERROR)   echo -e "${RED}✗ $*${NC}" ;;
        SUCCESS) echo -e "${GREEN}✓ $*${NC}" ;;
        WARN)    echo -e "${YELLOW}⚠ $*${NC}" ;;
        INFO)    echo -e "${BLUE}ℹ $*${NC}" ;;
        SYNC)    echo -e "${CYAN}⟳ $*${NC}" ;;
        *)       echo "  $*" ;;
    esac
}

vlog() {
    if [[ "$VERBOSE" == "true" ]]; then
        log "DEBUG" "$@"
    fi
}

# ─── Interactive Setup ────────────────────────────────────────────────────────
run_setup() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║          github-sync — First Time Setup         ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""

    # Check prerequisites
    local missing=false
    if ! command -v gh &>/dev/null; then
        echo "✗ GitHub CLI (gh) not found."
        echo "  Install: https://cli.github.com/"
        echo "    macOS:  brew install gh"
        echo "    Linux:  sudo apt install gh  /  sudo dnf install gh"
        missing=true
    else
        echo "✓ GitHub CLI found: $(gh --version | head -1)"
    fi

    if ! command -v git &>/dev/null; then
        echo "✗ git not found."
        missing=true
    else
        echo "✓ git found: $(git --version)"
    fi

    if ! command -v jq &>/dev/null; then
        echo "✗ jq not found."
        echo "  Install: brew install jq  /  sudo apt install jq"
        missing=true
    else
        echo "✓ jq found"
    fi

    if [[ "$missing" == "true" ]]; then
        echo ""
        echo "Please install the missing dependencies and re-run setup."
        exit 1
    fi

    # Check gh auth
    echo ""
    if gh auth status &>/dev/null; then
        local gh_user
        gh_user="$(gh api user --jq '.login' 2>/dev/null || echo "unknown")"
        echo "✓ Authenticated to GitHub as: $gh_user"
    else
        echo "✗ Not authenticated to GitHub."
        echo "  Run: gh auth login"
        exit 1
    fi

    # Gather config
    echo ""
    echo "── Configuration ──"
    echo ""

    # Git name
    local default_name
    default_name="$(git config --global user.name 2>/dev/null || echo "")"
    read -rp "Git user.name [$default_name]: " input_name
    local cfg_name="${input_name:-$default_name}"

    # Git email
    local default_email
    default_email="$(git config --global user.email 2>/dev/null || echo "")"
    read -rp "Git user.email [$default_email]: " input_email
    local cfg_email="${input_email:-$default_email}"

    # Projects dir
    local default_dir="$HOME/Projects"
    read -rp "Projects directory [$default_dir]: " input_dir
    local cfg_dir="${input_dir:-$default_dir}"

    # Protocol
    read -rp "Clone protocol (https/ssh) [https]: " input_proto
    local cfg_proto="${input_proto:-https}"

    # Include forks
    read -rp "Include forked repos? (true/false) [false]: " input_forks
    local cfg_forks="${input_forks:-false}"

    # Write config
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<CONF
# github-sync configuration
# Generated by: github-sync --setup
# Date: $(date '+%Y-%m-%d %H:%M:%S')
# Machine: $(hostname)

GITHUB_SYNC_DIR="$cfg_dir"
GITHUB_SYNC_GIT_NAME="$cfg_name"
GITHUB_SYNC_GIT_EMAIL="$cfg_email"
GITHUB_SYNC_PROTOCOL="$cfg_proto"
GITHUB_SYNC_FORKS="$cfg_forks"
GITHUB_SYNC_ARCHIVED="false"
CONF

    echo ""
    echo "✓ Config written to: $CONFIG_FILE"
    echo ""

    # Offer to install as background service
    if [[ "$(uname)" == "Darwin" ]]; then
        read -rp "Install as a background service (launchd)? (y/n) [n]: " install_service
        if [[ "$install_service" == "y" || "$install_service" == "Y" ]]; then
            read -rp "Sync interval in seconds [300]: " input_interval
            local svc_interval="${input_interval:-300}"
            install_launchd "$svc_interval"
        fi
    elif [[ "$(uname)" == "Linux" ]]; then
        read -rp "Install as a background service (systemd)? (y/n) [n]: " install_service
        if [[ "$install_service" == "y" || "$install_service" == "Y" ]]; then
            read -rp "Sync interval in seconds [300]: " input_interval
            local svc_interval="${input_interval:-300}"
            install_systemd "$svc_interval"
        fi
    fi

    echo ""
    echo "Setup complete! Run 'github-sync --dry-run' to preview, or 'github-sync' to sync."
    echo ""
}

# ─── macOS launchd service ────────────────────────────────────────────────────
install_launchd() {
    local interval="${1:-300}"
    local plist_dir="$HOME/Library/LaunchAgents"
    local plist_file="$plist_dir/com.github-sync.agent.plist"
    local script_path
    script_path="$(realpath "$0")"

    mkdir -p "$plist_dir"

    cat > "$plist_file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.github-sync.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>${script_path}</string>
    </array>
    <key>StartInterval</key>
    <integer>${interval}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${HOME}/.local/share/github-sync/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.local/share/github-sync/launchd-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLIST

    # Load the agent
    launchctl unload "$plist_file" 2>/dev/null || true
    launchctl load "$plist_file"

    echo "✓ Installed launchd agent: $plist_file"
    echo "  Syncing every ${interval}s. Runs at login."
    echo "  Stop:    launchctl unload $plist_file"
    echo "  Restart: launchctl unload $plist_file && launchctl load $plist_file"
}

# ─── Linux systemd service ───────────────────────────────────────────────────
install_systemd() {
    local interval="${1:-300}"
    local unit_dir="$HOME/.config/systemd/user"
    local script_path
    script_path="$(realpath "$0")"

    mkdir -p "$unit_dir"

    # Service unit
    cat > "$unit_dir/github-sync.service" <<SVC
[Unit]
Description=GitHub Sync - keep repos in sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${script_path}
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
SVC

    # Timer unit
    cat > "$unit_dir/github-sync.timer" <<TMR
[Unit]
Description=Run GitHub Sync periodically

[Timer]
OnBootSec=60
OnUnitActiveSec=${interval}s
Persistent=true

[Install]
WantedBy=timers.target
TMR

    systemctl --user daemon-reload
    systemctl --user enable --now github-sync.timer

    echo "✓ Installed systemd timer: github-sync.timer"
    echo "  Syncing every ${interval}s."
    echo "  Status:  systemctl --user status github-sync.timer"
    echo "  Stop:    systemctl --user stop github-sync.timer"
    echo "  Disable: systemctl --user disable github-sync.timer"
}

# ─── Status command ───────────────────────────────────────────────────────────
show_status() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║              github-sync — Status               ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    echo "Config: $CONFIG_FILE"
    echo "Projects: $PROJECTS_DIR"
    echo "Log: $LOG_FILE"
    echo ""

    if [[ ! -d "$PROJECTS_DIR" ]]; then
        echo "Projects directory does not exist yet."
        return
    fi

    printf "%-25s %-12s %-10s %-8s %s\n" "REPO" "BRANCH" "STATUS" "AHEAD" "BEHIND"
    printf "%-25s %-12s %-10s %-8s %s\n" "────" "──────" "──────" "─────" "──────"

    for dir in "$PROJECTS_DIR"/*/; do
        [[ -d "$dir/.git" ]] || continue
        local name branch status ahead behind
        name="$(basename "$dir")"
        branch="$(git -C "$dir" branch --show-current 2>/dev/null || echo "detached")"

        if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
            status="dirty"
        else
            status="clean"
        fi

        if git -C "$dir" rev-parse --abbrev-ref "@{upstream}" &>/dev/null; then
            ahead="$(git -C "$dir" rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo "?")"
            behind="$(git -C "$dir" rev-list --count "HEAD..@{upstream}" 2>/dev/null || echo "?")"
        else
            ahead="n/a"
            behind="n/a"
        fi

        printf "%-25s %-12s %-10s %-8s %s\n" "$name" "$branch" "$status" "$ahead" "$behind"
    done
    echo ""
}

# ─── Preflight Checks ────────────────────────────────────────────────────────
preflight() {
    local ok=true

    if ! command -v gh &>/dev/null; then
        log ERROR "GitHub CLI (gh) not installed. Run: github-sync --setup"
        ok=false
    fi

    if ! command -v git &>/dev/null; then
        log ERROR "git is not installed."
        ok=false
    fi

    if ! command -v jq &>/dev/null; then
        log ERROR "jq is not installed. Install with: brew install jq / apt install jq"
        ok=false
    fi

    if ! gh auth status &>/dev/null; then
        log ERROR "GitHub CLI not authenticated. Run: gh auth login"
        ok=false
    fi

    if [[ -z "$GIT_USER_NAME" || -z "$GIT_USER_EMAIL" ]]; then
        # Fall back to global git config
        GIT_USER_NAME="${GIT_USER_NAME:-$(git config --global user.name 2>/dev/null || echo "")}"
        GIT_USER_EMAIL="${GIT_USER_EMAIL:-$(git config --global user.email 2>/dev/null || echo "")}"
        if [[ -z "$GIT_USER_NAME" || -z "$GIT_USER_EMAIL" ]]; then
            log ERROR "Git identity not configured. Run: github-sync --setup"
            ok=false
        fi
    fi

    if [[ "$ok" == "false" ]]; then
        exit 1
    fi

    log SUCCESS "Preflight checks passed ($(hostname))"
}

# ─── Ensure git config is correct for a repo ─────────────────────────────────
ensure_git_config() {
    local repo_dir="$1"

    local current_name current_email
    current_name="$(git -C "$repo_dir" config user.name 2>/dev/null || echo "")"
    current_email="$(git -C "$repo_dir" config user.email 2>/dev/null || echo "")"

    if [[ "$current_name" != "$GIT_USER_NAME" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log INFO "[DRY-RUN] Would set user.name='$GIT_USER_NAME' in $repo_dir"
        else
            git -C "$repo_dir" config user.name "$GIT_USER_NAME"
            vlog "Set user.name='$GIT_USER_NAME' in $repo_dir"
        fi
    fi

    if [[ "$current_email" != "$GIT_USER_EMAIL" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log INFO "[DRY-RUN] Would set user.email='$GIT_USER_EMAIL' in $repo_dir"
        else
            git -C "$repo_dir" config user.email "$GIT_USER_EMAIL"
            vlog "Set user.email='$GIT_USER_EMAIL' in $repo_dir"
        fi
    fi
}

# ─── Check remote connectivity ───────────────────────────────────────────────
check_remote() {
    local repo_dir="$1"
    if git -C "$repo_dir" ls-remote --exit-code origin &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ─── Fetch all repos from GitHub ─────────────────────────────────────────────
fetch_repo_list() {
    local -a flags=(--limit 500)

    if [[ "$INCLUDE_FORKS" != "true" ]]; then
        flags+=(--source)
    fi

    if [[ "$INCLUDE_ARCHIVED" != "true" ]]; then
        flags+=(--no-archived)
    fi

    gh repo list "${flags[@]}" --json name,sshUrl,url,defaultBranchRef,isFork,isArchived
}

# ─── Get clone URL based on protocol preference ──────────────────────────────
get_clone_url() {
    local repo_json="$1"
    if [[ "$CLONE_PROTOCOL" == "ssh" ]]; then
        echo "$repo_json" | jq -r '.sshUrl'
    else
        echo "$repo_json" | jq -r '.url'
    fi
}

# ─── Sync a single repository ────────────────────────────────────────────────
sync_repo() {
    local repo_json="$1"
    local name default_branch clone_url is_fork is_archived
    name="$(echo "$repo_json" | jq -r '.name')"
    default_branch="$(echo "$repo_json" | jq -r '.defaultBranchRef.name // "main"')"
    clone_url="$(get_clone_url "$repo_json")"
    is_fork="$(echo "$repo_json" | jq -r '.isFork')"
    is_archived="$(echo "$repo_json" | jq -r '.isArchived')"

    local repo_dir="$PROJECTS_DIR/$name"

    echo ""
    log SYNC "Syncing: $name (branch: $default_branch)"

    # ── Clone if missing ──
    if [[ ! -d "$repo_dir" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log INFO "[DRY-RUN] Would clone $clone_url → $repo_dir"
            return 0
        fi

        log INFO "Cloning $name..."
        if git clone "$clone_url" "$repo_dir" 2>&1; then
            log SUCCESS "Cloned $name"
        else
            log ERROR "Failed to clone $name"
            return 1
        fi
    else
        vlog "$name already exists locally"
    fi

    # ── Verify it's a git repo ──
    if [[ ! -d "$repo_dir/.git" ]]; then
        log WARN "$repo_dir exists but is not a git repo — skipping"
        return 1
    fi

    # ── Ensure git config ──
    ensure_git_config "$repo_dir"

    # ── Check remote connectivity ──
    if ! check_remote "$repo_dir"; then
        log ERROR "$name: Cannot reach remote 'origin' — skipping sync"
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[DRY-RUN] Would fetch, pull, and push $name"
        return 0
    fi

    # ── Fetch ──
    git -C "$repo_dir" fetch --all --prune --quiet 2>&1 || {
        log WARN "$name: fetch failed"
    }

    # ── Stash if dirty working tree ──
    local stashed=false
    if [[ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]]; then
        log WARN "$name: Working tree is dirty — stashing changes before pull"
        git -C "$repo_dir" stash push -m "github-sync auto-stash $(date '+%Y%m%d-%H%M%S')" 2>&1 || true
        stashed=true
    fi

    # ── Pull (rebase to keep history clean) ──
    local current_branch
    current_branch="$(git -C "$repo_dir" branch --show-current 2>/dev/null || echo "")"

    if [[ -z "$current_branch" ]]; then
        log WARN "$name: Detached HEAD — skipping pull/push"
        return 0
    fi

    if git -C "$repo_dir" rev-parse --abbrev-ref "@{upstream}" &>/dev/null; then
        if git -C "$repo_dir" pull --rebase --quiet 2>&1; then
            log SUCCESS "$name: Pulled latest on $current_branch"
        else
            log ERROR "$name: Pull failed — attempting rebase abort"
            git -C "$repo_dir" rebase --abort 2>/dev/null || true
        fi
    else
        vlog "$name: Branch '$current_branch' has no upstream tracking — skipping pull"
    fi

    # ── Pop stash if we stashed ──
    if [[ "$stashed" == "true" ]]; then
        if git -C "$repo_dir" stash pop 2>&1; then
            log SUCCESS "$name: Restored stashed changes"
        else
            log WARN "$name: Stash pop had conflicts — changes remain in stash"
        fi
    fi

    # ── Push if we have unpushed commits ──
    if git -C "$repo_dir" rev-parse --abbrev-ref "@{upstream}" &>/dev/null; then
        local ahead
        ahead="$(git -C "$repo_dir" rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo "0")"
        if [[ "$ahead" -gt 0 ]]; then
            if [[ "$is_archived" == "true" ]]; then
                log WARN "$name: $ahead unpushed commit(s) but repo is archived — cannot push"
            else
                log INFO "$name: Pushing $ahead commit(s)..."
                if git -C "$repo_dir" push --quiet 2>&1; then
                    log SUCCESS "$name: Pushed $ahead commit(s)"
                else
                    log ERROR "$name: Push failed"
                fi
            fi
        else
            vlog "$name: Up to date"
        fi
    fi
}

# ─── Main sync cycle ─────────────────────────────────────────────────────────
run_sync() {
    log INFO "═══════════════════════════════════════════════════"
    log INFO "GitHub Sync — $(date '+%Y-%m-%d %H:%M:%S') — $(hostname)"
    log INFO "Projects dir: $PROJECTS_DIR"
    log INFO "Git identity: $GIT_USER_NAME <$GIT_USER_EMAIL>"
    log INFO "Protocol: $CLONE_PROTOCOL"
    log INFO "═══════════════════════════════════════════════════"

    # Ensure projects directory exists
    if [[ "$DRY_RUN" == "false" ]]; then
        mkdir -p "$PROJECTS_DIR"
    fi

    # Fetch repo list
    log INFO "Fetching repository list from GitHub..."
    local repos_json
    repos_json="$(fetch_repo_list)" || {
        log ERROR "Failed to fetch repository list"
        return 1
    }

    local repo_count
    repo_count="$(echo "$repos_json" | jq 'length')"
    log SUCCESS "Found $repo_count repositories on GitHub"

    # Count local-only dirs
    local remote_names
    remote_names="$(echo "$repos_json" | jq -r '.[].name')"

    local local_only=0
    if [[ -d "$PROJECTS_DIR" ]]; then
        for dir in "$PROJECTS_DIR"/*/; do
            [[ -d "$dir" ]] || continue
            local dirname
            dirname="$(basename "$dir")"
            if ! echo "$remote_names" | grep -qx "$dirname"; then
                local_only=$((local_only + 1))
                vlog "Local-only directory: $dirname"
            fi
        done
        if [[ $local_only -gt 0 ]]; then
            log INFO "$local_only local director(ies) not found on GitHub (won't be touched)"
        fi
    fi

    # Sync each repo
    local i=0 success=0 failed=0
    while IFS= read -r repo_json; do
        i=$((i + 1))
        if sync_repo "$repo_json"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done < <(echo "$repos_json" | jq -c '.[]')

    echo ""
    log INFO "═══════════════════════════════════════════════════"
    log SUCCESS "Sync complete: $success succeeded, $failed failed out of $repo_count repos"
    log INFO "═══════════════════════════════════════════════════"
}

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --loop)
            LOOP_INTERVAL="${2:-300}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --dir)
            PROJECTS_DIR="$2"
            shift 2
            ;;
        --setup)
            run_setup
            exit 0
            ;;
        --status)
            show_status
            exit 0
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# ─── Run ──────────────────────────────────────────────────────────────────────
preflight

if [[ "$LOOP_INTERVAL" -gt 0 ]]; then
    log INFO "Running in continuous mode (every ${LOOP_INTERVAL}s). Press Ctrl+C to stop."
    while true; do
        run_sync
        log INFO "Next sync in ${LOOP_INTERVAL}s..."
        sleep "$LOOP_INTERVAL"
    done
else
    run_sync
fi
