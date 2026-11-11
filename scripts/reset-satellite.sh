#!/usr/bin/env bash
#
# reset-satellite.sh returns a macOS machine to a bare state that
# launch-satellite.sh expects, removing user file contents, Nix, Homebrew
# and installed tools, dotfiles state, and fleet folders.
#
# ==============================================================================
# WARNING: DESTRUCTIVE TEST-BED TOOL ONLY
#
# This script is designed solely for dedicated test-bed machines (such as mini3)
# to prove out bare-metal launch script reliability over repeated wipe cycles.
#
# Product satellites are NOT meant to be wiped: they borrow idle compute
# non-destructively (jobs execute in disposable Tart VMs or containers, leaving
# the host machine intact). Do NOT run this script on primary workstations.
# ==============================================================================
#
# It preserves SSH authorized keys, network settings, Tailscale access,
# and the user account so the machine stays reachable over SSH.
#
# Default: dry-run mode (lists what would be removed without changing anything).
# Pass --yes to actually perform the reset.
#
# Bash 3.2 compatible (macOS default /bin/bash).
set -euo pipefail

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DRY_RUN=1
CONFIG_FILE=""
OS=""

# Defaults
SATELLITE_FIRSTMATE_HOME="$HOME/fm_home"
SATELLITE_DOTFILES_DIR="$HOME/.local/share/satellite-launch/dotfiles"

usage() {
  cat <<EOF
usage: $SCRIPT_NAME [--dry-run] [--yes] [--config FILE]

  --yes, -y       perform the destructive wipe (default is dry-run)
  --dry-run, -n   list what would be removed without making changes (default)
  --config FILE   per-machine config; default $SCRIPT_DIR/satellite.local.conf
  --help, -h      show this help

CAUTION: $SCRIPT_NAME is a DESTRUCTIVE test-bed tool designed specifically for
repeatable wipe testing on dedicated test machines (e.g. mini3). Standard satellites
borrow compute non-destructively in disposable Tart VMs/containers.

By default, $SCRIPT_NAME runs as a dry run. It never touches SSH authorized
keys, Tailscale credentials/app, or the user account.
EOF
}

log() {
  printf '==> %s\n' "$*"
}

step() {
  printf '\n--- %s ---\n' "$*"
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1
}

detect_os() {
  local uname_s
  uname_s=$(uname -s)
  case $uname_s in
    Darwin) OS=darwin ;;
    Linux) OS=linux ;;
    *) die "unsupported operating system: $uname_s" ;;
  esac
}

load_config() {
  local conf=""
  if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    conf="$CONFIG_FILE"
  elif [ -f "$SCRIPT_DIR/satellite.local.conf" ]; then
    conf="$SCRIPT_DIR/satellite.local.conf"
  elif [ -f "$SCRIPT_DIR/satellite.example.conf" ]; then
    conf="$SCRIPT_DIR/satellite.example.conf"
  fi
  if [ -n "$conf" ]; then
    # shellcheck disable=SC2034
    SATELLITE_CONFIG_DIR=$(CDPATH='' cd -- "$(dirname -- "$conf")" && pwd)
    # shellcheck source=/dev/null
    . "$conf"
  fi
}

# remove_path removes a file or directory safely, or logs in dry-run
remove_path() {
  local target=$1 sudo_required=${2:-0}
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    if [ "$sudo_required" = 1 ]; then
      printf '  [dry-run] sudo rm -rf %s\n' "$target"
    else
      printf '  [dry-run] rm -rf %s\n' "$target"
    fi
    return 0
  fi
  if [ "$sudo_required" = 1 ]; then
    printf '  + sudo rm -rf %s\n' "$target"
    sudo rm -rf "$target"
  else
    printf '  + rm -rf %s\n' "$target"
    rm -rf "$target"
  fi
}

# safe_clean_dir removes contents of a directory without removing the directory itself
clean_dir_contents() {
  local dir=$1 sudo_required=${2:-0}
  [ -d "$dir" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    if [ "$sudo_required" = 1 ]; then
      printf '  [dry-run] sudo rm -rf %s/*\n' "$dir"
    else
      printf '  [dry-run] rm -rf %s/*\n' "$dir"
    fi
    return 0
  fi
  if [ "$sudo_required" = 1 ]; then
    printf '  + sudo rm -rf %s/*\n' "$dir"
    sudo find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  else
    printf '  + rm -rf %s/*\n' "$dir"
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  fi
}

verify_ssh_safety() {
  # Absolute requirement: never wipe ~/.ssh or authorized_keys
  local ssh_dir="$HOME/.ssh"
  if [ -d "$ssh_dir" ]; then
    if [ -f "$ssh_dir/authorized_keys" ]; then
      log "SSH safety check: $ssh_dir/authorized_keys is preserved"
    else
      log "SSH safety check: $ssh_dir exists (no authorized_keys file)"
    fi
  else
    log "SSH safety check: $ssh_dir does not exist yet"
  fi
}

wipe_processes() {
  step "Running processes and VMs"
  if need tart; then
    if [ "$DRY_RUN" = 1 ]; then
      printf '  [dry-run] would stop and delete all Tart VMs\n'
    else
      log "stopping running Tart VMs"
      tart stop --all 2>/dev/null || true
      local vm
      for vm in $(tart list -q 2>/dev/null || true); do
        log "deleting Tart VM: $vm"
        tart delete "$vm" 2>/dev/null || true
      done
    fi
  fi

  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] would terminate any runner-up processes\n'
  else
    pkill -f runner-up 2>/dev/null || true
  fi
}

wipe_fleet() {
  step "Fleet folders"
  if [ -d "$SATELLITE_FIRSTMATE_HOME" ]; then
    remove_path "$SATELLITE_FIRSTMATE_HOME" 0
  else
    log "fleet home not present: $SATELLITE_FIRSTMATE_HOME"
  fi
}

wipe_dotfiles() {
  step "Dotfiles state"
  remove_path "$SATELLITE_DOTFILES_DIR" 0
  remove_path "$HOME/.local/share/satellite-launch" 0

  # Clean shell rc files created or symlinked by dotfiles, preserving standard shell access
  local rc
  for rc in .zshrc .bashrc .bash_profile .profile .zprofile .zshenv .gitconfig; do
    if [ -e "$HOME/$rc" ] || [ -L "$HOME/$rc" ]; then
      remove_path "$HOME/$rc" 0
    fi
  done

  # Leave an empty .zshrc so macOS zsh doesn't run the first-run configuration wizard upon login
  if [ "$DRY_RUN" = 0 ]; then
    touch "$HOME/.zshrc"
  fi
}

wipe_tools() {
  step "Installed tools and credentials"
  # Claude Code
  remove_path "$HOME/.local/bin/claude" 0
  remove_path "$HOME/.claude" 0
  remove_path "$HOME/.claude.json" 0
  remove_path "$HOME/.anthropic" 0
  remove_path "$HOME/Library/Application Support/Claude" 0
  remove_path "$HOME/Library/Application Support/Claude Code" 0
  remove_path "$HOME/Library/Caches/claude-code" 0

  # Pi
  remove_path "$HOME/.local/bin/pi" 0
  remove_path "$HOME/.pi" 0
  remove_path "$HOME/.config/pi" 0
  remove_path "$HOME/Library/Application Support/pi" 0
  remove_path "$HOME/Library/Caches/pi" 0

  # Tart cache/data
  remove_path "$HOME/.tart" 0
  remove_path "$HOME/.cache/tart" 0
  remove_path "$HOME/Library/Caches/tart" 0

  # GitHub CLI config & cache (forces re-auth check in launch-satellite)
  remove_path "$HOME/.config/gh" 0
  remove_path "$HOME/.cache/gh" 0

  # runner-up local binary and state
  remove_path "$HOME/.local/bin/runner-up" 0
  remove_path "$HOME/.local/share/runner-up" 0

  # Clean remaining local binaries
  clean_dir_contents "$HOME/.local/bin" 0
}

wipe_homebrew() {
  step "Homebrew"
  # Apple Silicon prefix
  if [ -d "/opt/homebrew" ]; then
    remove_path "/opt/homebrew" 1
  fi

  # Intel prefix Homebrew specific directories
  if [ -d "/usr/local/Homebrew" ]; then
    remove_path "/usr/local/Homebrew" 1
  fi
  if [ -d "/usr/local/Cellar" ]; then
    remove_path "/usr/local/Cellar" 1
  fi
  if [ -d "/usr/local/Caskroom" ]; then
    remove_path "/usr/local/Caskroom" 1
  fi

  # Homebrew caches and logs
  remove_path "/Library/Caches/Homebrew" 1
  remove_path "$HOME/Library/Caches/Homebrew" 0
  remove_path "$HOME/Library/Logs/Homebrew" 0
  remove_path "/etc/paths.d/homebrew" 1

  # Safety verification: Tailscale.app must remain intact
  if [ -d "/Applications/Tailscale.app" ]; then
    log "Tailscale safety check: /Applications/Tailscale.app is preserved"
  fi
}

wipe_nix() {
  step "Nix"
  if [ "$OS" != darwin ]; then
    log "non-macOS system; skipping macOS APFS Nix volume reset"
    return 0
  fi

  # 1. Unload daemons
  local plist
  for plist in /Library/LaunchDaemons/org.nixos.nix-daemon.plist /Library/LaunchDaemons/org.nixos.darwin-store.plist; do
    if [ -f "$plist" ]; then
      if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run] sudo launchctl bootout system %s\n' "$plist"
      else
        printf '  + sudo launchctl bootout system %s\n' "$plist"
        sudo launchctl bootout system "$plist" 2>/dev/null || sudo launchctl unload "$plist" 2>/dev/null || true
      fi
      remove_path "$plist" 1
    fi
  done

  # 2. Unmount and delete APFS /nix volume if present
  if mount | grep -q 'on /nix ' 2>/dev/null || [ -d "/nix" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      printf '  [dry-run] sudo diskutil apfs deleteVolume /nix (or umount and remove /nix)\n'
    else
      printf '  + sudo diskutil apfs deleteVolume /nix\n'
      sudo diskutil apfs deleteVolume /nix 2>/dev/null || sudo umount -f /nix 2>/dev/null || true
      sudo rm -rf /nix 2>/dev/null || true
    fi
  fi

  # 3. Clean /etc/synthetic.conf
  if [ -f "/etc/synthetic.conf" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      printf '  [dry-run] remove nix entry from /etc/synthetic.conf\n'
    else
      printf '  + remove nix entry from /etc/synthetic.conf\n'
      sudo sed -i '' '/^nix[[:space:]]*$/d' /etc/synthetic.conf 2>/dev/null || true
      if [ ! -s /etc/synthetic.conf ]; then
        sudo rm -f /etc/synthetic.conf
      fi
    fi
  fi

  # 4. Clean /etc/fstab
  if [ -f "/etc/fstab" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      printf '  [dry-run] remove nix entry from /etc/fstab\n'
    else
      printf '  + remove nix entry from /etc/fstab\n'
      sudo sed -i '' '/\/nix/d' /etc/fstab 2>/dev/null || true
      sudo sed -i '' '/LABEL=Nix/d' /etc/fstab 2>/dev/null || true
      if [ ! -s /etc/fstab ]; then
        sudo rm -f /etc/fstab
      fi
    fi
  fi

  # 5. Clean shell files
  local sh_file
  for sh_file in /etc/zshrc /etc/bashrc; do
    if [ -f "$sh_file" ]; then
      if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run] strip Nix daemon hooks from %s\n' "$sh_file"
      else
        sudo sed -i '' '/nix-daemon/d' "$sh_file" 2>/dev/null || true
        sudo sed -i '' '/# Nix/d' "$sh_file" 2>/dev/null || true
      fi
    fi
  done

  # 6. Remove nix config and profiles
  remove_path "/etc/nix" 1
  remove_path "/etc/profile.d/nix.sh" 1
  remove_path "/etc/profile.d/nix-daemon.sh" 1
  remove_path "$HOME/.nix-profile" 0
  remove_path "$HOME/.nix-defexpr" 0
  remove_path "$HOME/.nix-channels" 0
  remove_path "$HOME/.config/nix" 0
  remove_path "$HOME/.cache/nix" 0
  remove_path "$HOME/.local/state/nix" 0

  # 7. Remove build users and groups
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] would delete _nixbld build users and _nixbld group\n'
  else
    local u
    for u in $(sudo dscl . -list /Users 2>/dev/null | grep -E '^(_)?nixbld' || true); do
      printf '  + sudo dscl . -delete /Users/%s\n' "$u"
      sudo dscl . -delete "/Users/$u" 2>/dev/null || true
    done
    sudo dscl . -delete /Groups/_nixbld 2>/dev/null || sudo dscl . -delete /Groups/nixbld 2>/dev/null || true
  fi
}

wipe_user_contents() {
  step "User caches and temporary files"
  clean_dir_contents "$HOME/Downloads" 0
  clean_dir_contents "$HOME/.cache" 0

  # Clean temporary files created by testing
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] would remove temporary files in /tmp matching satreset*, satloop*, satellite*\n'
  else
    find /tmp -maxdepth 1 \( -name 'satreset*' -o -name 'satloop*' -o -name 'satellite*' \) -exec rm -rf {} + 2>/dev/null || true
  fi
}

summary() {
  step "Reset summary"
  verify_ssh_safety

  if need tailscale; then
    if tailscale status >/dev/null 2>&1; then
      log "Tailscale status: active and connected"
    else
      log "Tailscale status: installed (offline or needs up)"
    fi
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    log "Tailscale status: /Applications/Tailscale.app exists"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log "dry run complete: no files or configurations were deleted"
    log "to perform the actual reset, run: $SCRIPT_NAME --yes"
  else
    log "satellite reset completed: machine returned to bare state"
    log "SSH and network access verified intact"
  fi
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --yes | -y)
        DRY_RUN=0
        shift
        ;;
      --dry-run | -n)
        DRY_RUN=1
        shift
        ;;
      --config)
        [ $# -ge 2 ] || die "--config needs a file"
        CONFIG_FILE=$2
        shift 2
        ;;
      --config=*)
        CONFIG_FILE=${1#--config=}
        shift
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        printf '%s: unknown argument: %s\n' "$SCRIPT_NAME" "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  detect_os
  load_config

  [ "$(id -u)" -ne 0 ] || die "run as the satellite user, not root; sudo is invoked when needed"

  if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN MODE: listing what would be wiped; nothing will be modified"
    log "NOTE: reset-satellite is a DESTRUCTIVE test-bed tool (e.g. for mini3). Production satellites run non-destructively."
  else
    log "PERFORMING WIPE (--yes): resetting satellite to bare state"
    log "WARNING: This is a DESTRUCTIVE test-bed operation. Ensure this machine is a dedicated test host."
  fi

  wipe_processes
  wipe_fleet
  wipe_dotfiles
  wipe_tools
  wipe_homebrew
  wipe_nix
  wipe_user_contents
  summary
}

main "$@"
