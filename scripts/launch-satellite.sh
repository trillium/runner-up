#!/usr/bin/env bash
#
# launch-satellite.sh takes a bare macOS machine (Linux is a later target)
# to a satellite: a machine with Nix, Homebrew, the dotfiles, the Claude and
# Pi tools, a firstmate home, a tailnet short name and, where it applies, a
# runner-up place.
#
# The steps come from a small per-machine config file. Copy
# scripts/satellite.example.conf to scripts/satellite.local.conf (ignored by
# git), edit it, then run:
#
#   scripts/launch-satellite.sh --dry-run
#   scripts/launch-satellite.sh
#
# See docs/satellite-launch.md for every setting. Credentials never belong in
# the config: put them in scripts/satellite.local.env (also ignored by git) or
# type them when a step asks.
#
# The script is written for bash 3.2, the bash macOS ships, so it avoids
# associative arrays, namerefs, mapfile and lower-case expansion.
set -euo pipefail

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DRY_RUN=0
YES_MODE=0
STOP_ON_MANUAL=0
TARGET_STEP=""
CONFIG_FILE=""
OS=""

# Defaults. The config file overrides any of them.
SATELLITE_OS=auto
SATELLITE_HOSTNAME=""
SATELLITE_USERNAME=""
SATELLITE_TAILNET_NAME=""
SATELLITE_ENV_FILE="$SCRIPT_DIR/satellite.local.env"
SATELLITE_DOTFILES_REPO=""
SATELLITE_DOTFILES_REF=main
SATELLITE_DOTFILES_DIR="$HOME/.local/share/satellite-launch/dotfiles"
SATELLITE_DOTFILES_INSTALL=install.sh
SATELLITE_DOTFILES_INSTALL_ARGS=()
SATELLITE_DOTFILES_HARDCODED_USERNAME=trilliumsmith
SATELLITE_DOTFILES_NEEDS_SUDO=0
SATELLITE_DOTFILES_NEEDS_AUTH=0
SATELLITE_TOOLS=()
SATELLITE_ACCOUNTS=()
SATELLITE_TAILSCALE_INSTALL=cask
SATELLITE_FIRSTMATE_HOME="$HOME/fm_home"
SATELLITE_FIRSTMATE_FLEET=""
SATELLITE_FIRSTMATE_REPO=""
SATELLITE_FIRSTMATE_REF=main
SATELLITE_FIRSTMATE_INSTALL=""
SATELLITE_FIRSTMATE_NEEDS_AUTH=0
SATELLITE_RUNNER_UP_MODE=auto
SATELLITE_RUNNER_UP_MACHINE=""
SATELLITE_RUNNER_UP_SSH=""
SATELLITE_RUNNER_UP_PROVIDER=""
SATELLITE_RUNNER_UP_IMAGE=""
SATELLITE_RUNNER_UP_POOLS=()
SATELLITE_RUNNER_UP_PLACES=0
SATELLITE_RUNNER_UP_PLACE_CORES=0
SATELLITE_RUNNER_UP_PLACE_MEMORY=0
SATELLITE_RUNNER_UP_COORDINATOR=""

usage() {
  cat <<EOF
usage: $SCRIPT_NAME [--dry-run] [--yes] [--stop-on-manual] [--step NAME] [--config FILE]

  --yes, -y           auto-confirm prompts for automated steps
  --stop-on-manual    stop and exit (code 10) on steps requiring human sign-in
  --step NAME         run only the named step (hostname, nix, homebrew, dotfiles,
                      tools, accounts, firstmate, tailnet, runner_up)
  --dry-run, -n       print every step without running it
  --config FILE       the per-machine config; default $SCRIPT_DIR/satellite.local.conf
  --help, -h          show this help

Start from scripts/satellite.example.conf. The full reference is in
docs/satellite-launch.md.
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

# ask stops the script until the operator agrees. Every step that needs a
# login, a credential or sudo goes through it.
ask() {
  local prompt=$1 answer
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] would ask: %s\n' "$prompt"
    return 0
  fi
  if [ "$YES_MODE" = 1 ]; then
    log "auto-confirming: $prompt"
    return 0
  fi
  if [ ! -r /dev/tty ]; then
    die "cannot ask \"$prompt\": no terminal; run this script interactively"
  fi
  printf '%s [y/N] ' "$prompt"
  read -r answer </dev/tty || die "no answer to \"$prompt\""
  case $answer in
    y | Y | yes | YES) return 0 ;;
    *) die "operator declined: $prompt" ;;
  esac
}

# run prints a command and runs it, or only prints it in a dry run.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] %s\n' "$(printf '%q ' "$@")"
    return 0
  fi
  printf '  + %s\n' "$(printf '%q ' "$@")"
  "$@"
}

# run_shell is run for a command that is a pipeline or a command string.
run_shell() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] %s\n' "$1"
    return 0
  fi
  printf '  + %s\n' "$1"
  bash -c "$1"
}

# sudo_run asks before anything that needs sudo.
sudo_run() {
  local why=$1
  shift
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] sudo %s\n' "$(printf '%q ' "$@")"
    return 0
  fi
  ask "$why"
  printf '  + sudo %s\n' "$(printf '%q ' "$@")"
  sudo "$@"
}

quote_command() {
  local out="" arg
  for arg in "$@"; do
    out="$out$(printf '%q ' "$arg")"
  done
  printf '%s' "${out% }"
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

prepare_path() {
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH" ;;
  esac
  export PATH
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    # shellcheck source=/dev/null
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi
}

file_mode() {
  if [ "$OS" = darwin ]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

load_config() {
  [ -f "$CONFIG_FILE" ] || die "no config at $CONFIG_FILE; copy scripts/satellite.example.conf there"
  # The config reads this to find files beside itself.
  # shellcheck disable=SC2034
  SATELLITE_CONFIG_DIR=$(CDPATH='' cd -- "$(dirname -- "$CONFIG_FILE")" && pwd)
  # shellcheck source=/dev/null
  . "$CONFIG_FILE"
  if [ -n "${SATELLITE_ENV_FILE:-}" ] && [ -f "$SATELLITE_ENV_FILE" ]; then
    local mode
    mode=$(file_mode "$SATELLITE_ENV_FILE")
    case $mode in
      600 | 400) ;;
      *) log "warning: $SATELLITE_ENV_FILE is readable by others (mode $mode); run: chmod 600 $SATELLITE_ENV_FILE" ;;
    esac
    set -a
    # shellcheck source=/dev/null
    . "$SATELLITE_ENV_FILE"
    set +a
  fi
}

validate_name() {
  local what=$1 value=$2
  [ -n "$value" ] || die "$what is empty"
  case $value in
    -*) die "$what must not start with a dash: $value" ;;
    *[!A-Za-z0-9.-]*) die "$what has characters other than letters, digits, dots and dashes: $value" ;;
  esac
  [ "${#value}" -le 63 ] || die "$what is longer than 63 characters: $value"
}

validate_config() {
  local tool account mode provider
  if [ "$SATELLITE_OS" != auto ] && [ "$SATELLITE_OS" != "$OS" ]; then
    die "SATELLITE_OS is $SATELLITE_OS but this machine is $OS"
  fi
  validate_name "SATELLITE_HOSTNAME" "$SATELLITE_HOSTNAME"
  [ -n "$SATELLITE_USERNAME" ] || die "SATELLITE_USERNAME is empty"
  case $SATELLITE_USERNAME in
    -*) die "SATELLITE_USERNAME must not start with a dash: $SATELLITE_USERNAME" ;;
    *[!A-Za-z0-9._-]*) die "SATELLITE_USERNAME has characters other than letters, digits, dots, underscores and dashes: $SATELLITE_USERNAME" ;;
  esac
  validate_name "SATELLITE_TAILNET_NAME" "$SATELLITE_TAILNET_NAME"

  if [ "${#SATELLITE_TOOLS[@]}" -gt 0 ]; then
    for tool in "${SATELLITE_TOOLS[@]}"; do
      case $tool in
        claude | pi | gh | tailscale | tart) ;;
        *) die "unknown tool in SATELLITE_TOOLS: $tool (known: claude, pi, gh, tailscale, tart)" ;;
      esac
    done
  fi
  if [ "${#SATELLITE_ACCOUNTS[@]}" -gt 0 ]; then
    for account in "${SATELLITE_ACCOUNTS[@]}"; do
      case $account in
        github | tailscale | claude | pi) ;;
        *) die "unknown account in SATELLITE_ACCOUNTS: $account (known: github, tailscale, claude, pi)" ;;
      esac
    done
  fi

  case $SATELLITE_TAILSCALE_INSTALL in
    cask | formula) ;;
    *) die "SATELLITE_TAILSCALE_INSTALL must be cask or formula" ;;
  esac

  mode=$SATELLITE_RUNNER_UP_MODE
  case $mode in
    auto | off | print | local | ssh) ;;
    *) die "SATELLITE_RUNNER_UP_MODE must be auto, off, print, local or ssh" ;;
  esac
  if [ "$mode" = auto ]; then
    if [ -n "$SATELLITE_RUNNER_UP_COORDINATOR" ]; then mode=print; else mode=local; fi
  fi
  if [ "$mode" = print ] || [ "$mode" = ssh ]; then
    [ -n "$SATELLITE_RUNNER_UP_SSH" ] || die "$mode mode needs SATELLITE_RUNNER_UP_SSH: the coordinator reaches this machine over SSH at that destination"
  fi
  if [ "$mode" = ssh ]; then
    [ -n "$SATELLITE_RUNNER_UP_COORDINATOR" ] || die "ssh mode needs SATELLITE_RUNNER_UP_COORDINATOR"
  fi
  provider=$SATELLITE_RUNNER_UP_PROVIDER
  case $provider in
    "" | tart | host | container) ;;
    *) die "SATELLITE_RUNNER_UP_PROVIDER must be tart, host or container on a Mac (empty picks tart)" ;;
  esac
  if [ "$provider" = tart ] && [ -z "$SATELLITE_RUNNER_UP_IMAGE" ]; then
    die "a tart place needs SATELLITE_RUNNER_UP_IMAGE, such as ghcr.io/cirruslabs/macos-sequoia-base:latest"
  fi

  if [ -n "$SATELLITE_FIRSTMATE_INSTALL" ] && [ -z "$SATELLITE_FIRSTMATE_REPO" ]; then
    die "SATELLITE_FIRSTMATE_INSTALL needs SATELLITE_FIRSTMATE_REPO"
  fi

  if grep -Eq '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|tskey-[A-Za-z0-9-]{10,})' "$CONFIG_FILE"; then
    die "$CONFIG_FILE looks like it contains a credential; put credentials in $SATELLITE_ENV_FILE (ignored by git) instead"
  fi
}

step_hostname() {
  step "Hostname"
  ask "Setting the machine's name to $SATELLITE_HOSTNAME needs sudo. Continue?"
  if [ "$OS" = darwin ]; then
    run sudo scutil --set HostName "$SATELLITE_HOSTNAME"
    run sudo scutil --set LocalHostName "$SATELLITE_HOSTNAME"
    run sudo scutil --set ComputerName "$SATELLITE_HOSTNAME"
  else
    run sudo hostnamectl set-hostname "$SATELLITE_HOSTNAME"
  fi
}

step_nix() {
  step "Nix"
  if need nix || [ -x /nix/var/nix/profiles/default/bin/nix ]; then
    log "Nix is already installed"
    prepare_path
    return 0
  fi
  ask "Nix's installer creates /nix and needs sudo. Continue?"
  if [ "$OS" = linux ]; then
    run_shell 'curl -fsSL https://nixos.org/nix/install | sh -s -- --daemon'
  else
    run_shell 'curl -fsSL https://nixos.org/nix/install | sh'
  fi
  prepare_path
}

step_homebrew() {
  step "Homebrew"
  if need brew || [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ]; then
    log "Homebrew is already installed"
    prepare_path
    return 0
  fi
  ask "Homebrew's installer needs sudo to create its prefix. Continue?"
  # shellcheck disable=SC2016
  run_shell 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  prepare_path
}

replace_username() {
  local dir=$1 old=$2 new=$3 file files
  files=$(git -C "$dir" grep -Il -e "$old" -- . || true)
  if [ -z "$files" ]; then
    log "no tracked files in $dir contain $old"
    return 0
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    printf '  + replace %s with %s in %s\n' "$old" "$new" "$file"
    OLD=$old NEW=$new perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$dir/$file"
  done <<EOF
$files
EOF
}

step_dotfiles() {
  step "Dotfiles"
  if [ -z "$SATELLITE_DOTFILES_REPO" ]; then
    log "SATELLITE_DOTFILES_REPO is empty; skipping the dotfiles"
    return 0
  fi
  if [ "$SATELLITE_DOTFILES_NEEDS_AUTH" = 1 ]; then
    ask "Cloning $SATELLITE_DOTFILES_REPO may need your git credentials. Continue?"
  fi
  if ! need git; then
    if [ "$DRY_RUN" = 1 ]; then
      log "note: git is not installed; the real run would stop here"
    else
      die "the dotfiles need git; install the Xcode command line tools or run this step after Homebrew"
    fi
  fi
  if [ -d "$SATELLITE_DOTFILES_DIR/.git" ]; then
    log "updating the dotfiles in $SATELLITE_DOTFILES_DIR"
    run git -C "$SATELLITE_DOTFILES_DIR" fetch --depth 1 origin "$SATELLITE_DOTFILES_REF"
    run git -C "$SATELLITE_DOTFILES_DIR" checkout --detach FETCH_HEAD
  else
    run mkdir -p "$(dirname "$SATELLITE_DOTFILES_DIR")"
    run git clone --depth 1 --branch "$SATELLITE_DOTFILES_REF" "$SATELLITE_DOTFILES_REPO" "$SATELLITE_DOTFILES_DIR"
  fi
  if [ -n "$SATELLITE_DOTFILES_HARDCODED_USERNAME" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      log "[dry-run] would replace $SATELLITE_DOTFILES_HARDCODED_USERNAME with $SATELLITE_USERNAME in $SATELLITE_DOTFILES_DIR"
    else
      replace_username "$SATELLITE_DOTFILES_DIR" "$SATELLITE_DOTFILES_HARDCODED_USERNAME" "$SATELLITE_USERNAME"
    fi
  fi
  if [ -z "$SATELLITE_DOTFILES_INSTALL" ]; then
    log "SATELLITE_DOTFILES_INSTALL is empty; leaving the clone at $SATELLITE_DOTFILES_DIR"
    return 0
  fi
  if [ ! -f "$SATELLITE_DOTFILES_DIR/$SATELLITE_DOTFILES_INSTALL" ] && [ "$DRY_RUN" != 1 ]; then
    die "no dotfiles installer at $SATELLITE_DOTFILES_DIR/$SATELLITE_DOTFILES_INSTALL"
  fi
  if [ "$SATELLITE_DOTFILES_NEEDS_SUDO" = 1 ]; then
    if [ "${#SATELLITE_DOTFILES_INSTALL_ARGS[@]}" -gt 0 ]; then
      sudo_run "The dotfiles installer needs sudo. Continue?" bash "$SATELLITE_DOTFILES_DIR/$SATELLITE_DOTFILES_INSTALL" "${SATELLITE_DOTFILES_INSTALL_ARGS[@]}"
    else
      sudo_run "The dotfiles installer needs sudo. Continue?" bash "$SATELLITE_DOTFILES_DIR/$SATELLITE_DOTFILES_INSTALL"
    fi
  else
    if [ "${#SATELLITE_DOTFILES_INSTALL_ARGS[@]}" -gt 0 ]; then
      run bash "$SATELLITE_DOTFILES_DIR/$SATELLITE_DOTFILES_INSTALL" "${SATELLITE_DOTFILES_INSTALL_ARGS[@]}"
    else
      run bash "$SATELLITE_DOTFILES_DIR/$SATELLITE_DOTFILES_INSTALL"
    fi
  fi
}

brew_install() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] brew install %s\n' "$*"
    return 0
  fi
  need brew || die "Homebrew is needed to install $*; run the Homebrew step first"
  run brew install "$@"
}

tailscale_cli() {
  if need tailscale; then
    command -v tailscale
    return 0
  fi
  if [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    printf '%s\n' /Applications/Tailscale.app/Contents/MacOS/Tailscale
    return 0
  fi
  return 1
}

install_tool() {
  local tool=$1
  case $tool in
    claude)
      if need claude; then
        log "claude is already installed"
        return 0
      fi
      log "installing Claude Code"
      run_shell 'curl -fsSL https://claude.ai/install.sh | bash'
      ;;
    pi)
      if need pi; then
        log "pi is already installed"
        return 0
      fi
      log "installing Pi"
      run_shell 'curl -fsSL https://pi.dev/install.sh | sh'
      ;;
    gh)
      if need gh; then
        log "gh is already installed"
        return 0
      fi
      brew_install gh
      ;;
    tailscale)
      if tailscale_cli >/dev/null 2>&1; then
        log "tailscale is already installed"
        return 0
      fi
      if [ "$SATELLITE_TAILSCALE_INSTALL" = formula ]; then
        brew_install tailscale
      else
        brew_install --cask tailscale
      fi
      ;;
    tart)
      if need tart; then
        log "tart is already installed"
        return 0
      fi
      brew_install cirruslabs/cli/tart
      ;;
  esac
}

step_tools() {
  step "Tools"
  if [ "${#SATELLITE_TOOLS[@]}" -eq 0 ]; then
    log "SATELLITE_TOOLS is empty; installing nothing"
    return 0
  fi
  local tool
  for tool in "${SATELLITE_TOOLS[@]}"; do
    install_tool "$tool"
  done
}

account_github() {
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would check gh auth status and run gh auth login if needed"
    return 0
  fi
  if ! need gh; then
    die "GitHub sign-in needs gh; add gh to SATELLITE_TOOLS"
  fi
  if gh auth status >/dev/null 2>&1; then
    log "GitHub is already signed in"
    return 0
  fi
  if [ "$STOP_ON_MANUAL" = 1 ]; then
    log "MANUAL_STEP_STOP: github (GitHub authentication required via gh auth login)"
    exit 10
  fi
  ask "GitHub sign-in opens a browser and needs your account. Continue?"
  gh auth login
  gh auth status >/dev/null 2>&1 || die "gh auth status still fails after sign-in"
}

account_tailscale() {
  local cli
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would sign in to Tailscale with tailscale up"
    return 0
  fi
  if ! cli=$(tailscale_cli); then
    die "Tailscale sign-in needs tailscale; add tailscale to SATELLITE_TOOLS"
  fi
  if "$cli" status >/dev/null 2>&1; then
    log "Tailscale is already signed in"
    return 0
  fi
  if [ "$STOP_ON_MANUAL" = 1 ]; then
    log "MANUAL_STEP_STOP: tailscale (Tailscale authentication required via tailscale up)"
    exit 10
  fi
  ask "Tailscale sign-in opens a browser and needs your account. Continue?"
  "$cli" up
  "$cli" status >/dev/null 2>&1 || die "tailscale status still fails after sign-in"
}

account_agent() {
  local name=$1
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would ask you to sign in to $name and then check $name --version"
    return 0
  fi
  if ! need "$name"; then
    die "$name sign-in needs $name; add $name to SATELLITE_TOOLS"
  fi
  local is_signed_in=0
  case $name in
    claude)
      if [ -f "$HOME/.claude.json" ] || [ -d "$HOME/.claude" ] || [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        is_signed_in=1
      fi
      ;;
    pi)
      if [ -f "$HOME/.pi" ] || [ -d "$HOME/.config/pi" ]; then
        is_signed_in=1
      fi
      ;;
  esac
  if [ "$is_signed_in" = 1 ]; then
    log "$name is already signed in"
    return 0
  fi
  if [ "$STOP_ON_MANUAL" = 1 ]; then
    log "MANUAL_STEP_STOP: $name ($name sign-in required via $name /login)"
    exit 10
  fi
  log "Sign in to $name in another terminal: run $name, then /login"
  ask "Press y once $name is signed in."
  "$name" --version >/dev/null 2>&1 || die "$name --version failed after sign-in"
}

step_accounts() {
  step "Accounts"
  if [ "${#SATELLITE_ACCOUNTS[@]}" -eq 0 ]; then
    log "SATELLITE_ACCOUNTS is empty; signing in to nothing"
    return 0
  fi
  local account
  for account in "${SATELLITE_ACCOUNTS[@]}"; do
    case $account in
      github) account_github ;;
      tailscale) account_tailscale ;;
      claude | pi) account_agent "$account" ;;
    esac
  done
}

step_firstmate() {
  step "Firstmate home"
  run mkdir -p "$SATELLITE_FIRSTMATE_HOME"
  if [ -n "$SATELLITE_FIRSTMATE_FLEET" ]; then
    run mkdir -p "$SATELLITE_FIRSTMATE_HOME/$SATELLITE_FIRSTMATE_FLEET"
    run mkdir -p "$SATELLITE_FIRSTMATE_HOME/$SATELLITE_FIRSTMATE_FLEET/state"
    run mkdir -p "$SATELLITE_FIRSTMATE_HOME/$SATELLITE_FIRSTMATE_FLEET/config"
    run mkdir -p "$SATELLITE_FIRSTMATE_HOME/$SATELLITE_FIRSTMATE_FLEET/bin"
    run mkdir -p "$SATELLITE_FIRSTMATE_HOME/$SATELLITE_FIRSTMATE_FLEET/data"
    run mkdir -p "$SATELLITE_FIRSTMATE_HOME/$SATELLITE_FIRSTMATE_FLEET/.agents"
  fi
  if [ -n "$SATELLITE_FIRSTMATE_REPO" ]; then
    if [ "$SATELLITE_FIRSTMATE_NEEDS_AUTH" = 1 ]; then
      ask "Cloning $SATELLITE_FIRSTMATE_REPO may need your git credentials. Continue?"
    fi
    if ! need git; then
      if [ "$DRY_RUN" = 1 ]; then
        log "note: git is not installed; the real run would stop here"
      else
        die "the firstmate source needs git"
      fi
    fi
    if [ -d "$SATELLITE_FIRSTMATE_HOME/.source/.git" ]; then
      log "updating the firstmate source in $SATELLITE_FIRSTMATE_HOME/.source"
      run git -C "$SATELLITE_FIRSTMATE_HOME/.source" fetch --depth 1 origin "$SATELLITE_FIRSTMATE_REF"
      run git -C "$SATELLITE_FIRSTMATE_HOME/.source" checkout --detach FETCH_HEAD
    else
      run git clone --depth 1 --branch "$SATELLITE_FIRSTMATE_REF" "$SATELLITE_FIRSTMATE_REPO" "$SATELLITE_FIRSTMATE_HOME/.source"
    fi
    if [ -n "$SATELLITE_FIRSTMATE_INSTALL" ]; then
      if [ ! -f "$SATELLITE_FIRSTMATE_HOME/.source/$SATELLITE_FIRSTMATE_INSTALL" ] && [ "$DRY_RUN" != 1 ]; then
        die "no firstmate installer at $SATELLITE_FIRSTMATE_HOME/.source/$SATELLITE_FIRSTMATE_INSTALL"
      fi
      run bash "$SATELLITE_FIRSTMATE_HOME/.source/$SATELLITE_FIRSTMATE_INSTALL"
    fi
  fi
}

step_tailnet() {
  step "Tailnet short name"
  local cli
  if ! cli=$(tailscale_cli); then
    if [ "$DRY_RUN" = 1 ]; then
      log "[dry-run] would set the tailnet hostname to $SATELLITE_TAILNET_NAME with tailscale"
      return 0
    fi
    die "setting the tailnet name needs tailscale; add tailscale to SATELLITE_TOOLS"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would run: $cli set --hostname $SATELLITE_TAILNET_NAME"
    return 0
  fi
  if ! "$cli" status >/dev/null 2>&1; then
    ask "Tailscale is not signed in; it needs your account. Continue?"
    "$cli" up
    "$cli" status >/dev/null 2>&1 || die "tailscale status still fails after sign-in"
  fi
  run "$cli" set --hostname "$SATELLITE_TAILNET_NAME"
}

machine_add_args() {
  MACHINE_ADD_ARGS=(machine add "$SATELLITE_RUNNER_UP_MACHINE")
  if [ -n "$SATELLITE_RUNNER_UP_SSH" ]; then
    MACHINE_ADD_ARGS+=(--ssh "$SATELLITE_RUNNER_UP_SSH")
  fi
  if [ -n "$SATELLITE_RUNNER_UP_PROVIDER" ]; then
    MACHINE_ADD_ARGS+=(--provider "$SATELLITE_RUNNER_UP_PROVIDER")
  fi
  if [ -n "$SATELLITE_RUNNER_UP_IMAGE" ]; then
    MACHINE_ADD_ARGS+=(--image "$SATELLITE_RUNNER_UP_IMAGE")
  fi
  if [ "$SATELLITE_RUNNER_UP_PLACES" -gt 0 ]; then
    MACHINE_ADD_ARGS+=(--places "$SATELLITE_RUNNER_UP_PLACES")
  fi
  if [ "$SATELLITE_RUNNER_UP_PLACE_CORES" -gt 0 ]; then
    MACHINE_ADD_ARGS+=(--place-cores "$SATELLITE_RUNNER_UP_PLACE_CORES")
  fi
  if [ "$SATELLITE_RUNNER_UP_PLACE_MEMORY" -gt 0 ]; then
    MACHINE_ADD_ARGS+=(--place-memory "$SATELLITE_RUNNER_UP_PLACE_MEMORY")
  fi
  if [ "${#SATELLITE_RUNNER_UP_POOLS[@]}" -gt 0 ]; then
    local pool
    for pool in "${SATELLITE_RUNNER_UP_POOLS[@]}"; do
      MACHINE_ADD_ARGS+=(--pool "$pool")
    done
  fi
}

step_runner_up() {
  step "runner-up place"
  local mode=$SATELLITE_RUNNER_UP_MODE
  if [ "$mode" = auto ]; then
    if [ -n "$SATELLITE_RUNNER_UP_COORDINATOR" ]; then mode=print; else mode=local; fi
  fi
  case $mode in
    off)
      log "runner-up registration is off"
      return 0
      ;;
  esac

  [ -n "$SATELLITE_RUNNER_UP_MACHINE" ] || SATELLITE_RUNNER_UP_MACHINE=$SATELLITE_HOSTNAME
  machine_add_args
  local cmd
  cmd=$(quote_command runner-up "${MACHINE_ADD_ARGS[@]}")

  case $mode in
    local)
      if ! need runner-up; then
        if [ "$DRY_RUN" = 1 ]; then
          log "[dry-run] runner-up is not installed; the real run would stop"
          printf '  [dry-run] %s\n' "$cmd"
          return 0
        fi
        die "runner-up is not installed; install it or set SATELLITE_RUNNER_UP_MODE=print"
      fi
      ask "runner-up machine add writes the local setup and may reach the machine over SSH. Continue?"
      log "registering this machine in the local setup"
      run runner-up "${MACHINE_ADD_ARGS[@]}"
      ;;
    print)
      log "run this on the coordinator ($SATELLITE_RUNNER_UP_COORDINATOR):"
      printf '  %s\n' "$cmd"
      ;;
    ssh)
      ask "Registering this machine runs runner-up machine add on $SATELLITE_RUNNER_UP_COORDINATOR over SSH. Continue?"
      run ssh "$SATELLITE_RUNNER_UP_COORDINATOR" "$cmd"
      ;;
  esac
}

summary() {
  step "Summary"
  if [ "$DRY_RUN" = 1 ]; then
    log "dry run complete; nothing was changed"
    return 0
  fi
  log "satellite steps finished"
  if [ "$SATELLITE_RUNNER_UP_MODE" = print ]; then
    log "next: run the runner-up command printed above on the coordinator, then runner-up check-config"
  fi
}

run_step() {
  local name=$1 func=$2
  if [ -n "$TARGET_STEP" ] && [ "$TARGET_STEP" != "$name" ]; then
    return 0
  fi
  "$func"
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run | -n)
        DRY_RUN=1
        shift
        ;;
      --yes | -y)
        YES_MODE=1
        shift
        ;;
      --stop-on-manual)
        STOP_ON_MANUAL=1
        shift
        ;;
      --step)
        [ $# -ge 2 ] || die "--step needs a step name"
        TARGET_STEP=$2
        shift 2
        ;;
      --step=*)
        TARGET_STEP=${1#--step=}
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

  if [ -z "$CONFIG_FILE" ]; then
    CONFIG_FILE="$SCRIPT_DIR/satellite.local.conf"
  fi
  detect_os
  load_config
  prepare_path
  validate_config

  [ "$(id -u)" -ne 0 ] || die "run as the satellite user, not root; the script asks before each sudo step"

  log "satellite $SATELLITE_HOSTNAME ($OS), user $SATELLITE_USERNAME"
  if [ "$DRY_RUN" = 1 ]; then
    log "dry run: every step is printed and nothing is run"
  fi

  run_step hostname step_hostname
  run_step nix step_nix
  run_step homebrew step_homebrew
  run_step dotfiles step_dotfiles
  run_step tools step_tools
  run_step accounts step_accounts
  run_step firstmate step_firstmate
  run_step tailnet step_tailnet
  run_step runner_up step_runner_up
  summary
}

main "$@"
