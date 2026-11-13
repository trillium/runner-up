#!/usr/bin/env bash
#
# reset-loop.sh drives repeated reset and launch-satellite cycles against
# a remote machine over SSH, measuring duration, step-by-step pass/fail,
# reachability, and manual-step stops.
#
# Designed for validating launch reliability on bare or wedged Macs (e.g. mini3)
# without requiring anything pre-installed on the target host beyond SSH.
#
# Bash 3.2 compatible.
set -euo pipefail

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

# Defaults
HOST=""
ROUNDS=1
CONFIG_FILE=""
OUTPUT_FILE="$REPO_ROOT/docs/reset-loop-results.md"
SSH_TIMEOUT=15
DRY_RUN=0
BATCH_MODE=0
KEEP_REMOTE=0
SUDO_PASSWORD_FILE=""
ENABLE_RESET=1

usage() {
  cat <<EOF
usage: $SCRIPT_NAME [OPTIONS] --host HOST
       $SCRIPT_NAME [OPTIONS] HOST

  --host HOST, -h HOST     remote SSH host alias or destination (e.g. mini3)
  --rounds N, -n N         number of reset/launch rounds to run (default: 1)
  --config FILE            per-machine config; default scripts/satellite.local.conf
  --output FILE, -o FILE   results markdown file; default docs/reset-loop-results.md
  --ssh-timeout SECS       SSH connection timeout in seconds (default: 15)
  --no-reset               non-destructive lifecycle mode: measure setup without wiping host
  --reset                  destructive test-bed mode: wipe bare before launch (default)
  --dry-run                run reset and launch in dry-run mode
  --batch                  non-interactive mode (do not wait at manual prompts)
  --sudo-password-file F   local owner-only file holding the host's sudo password; copied
                           to the host for this run only, removed afterwards, never logged
  --keep-remote            keep transferred scripts on remote host for inspection
  --help                   show this help

Modes:
  Primary (Non-destructive):
    $SCRIPT_NAME --host satellite-1 --no-reset
    Measures setup, pool join, and teardown while leaving host intact.

  Test-bed (Destructive):
    $SCRIPT_NAME --host mini3 --rounds 3 --reset
    Proves bare-metal setup reliability by wiping and rebuilding over N rounds.
EOF
}

log() {
  printf '==> %s\n' "$*" >&2
}

step_hdr() {
  printf '\n--- %s ---\n' "$*"
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

# Parse CLI arguments
parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --host | -h)
        [ $# -ge 2 ] || die "--host requires a host alias or address"
        HOST=$2
        shift 2
        ;;
      --rounds | -n)
        [ $# -ge 2 ] || die "--rounds requires an integer"
        ROUNDS=$2
        shift 2
        ;;
      --config)
        [ $# -ge 2 ] || die "--config requires a file path"
        CONFIG_FILE=$2
        shift 2
        ;;
      --config=*)
        CONFIG_FILE=${1#--config=}
        shift
        ;;
      --output | -o)
        [ $# -ge 2 ] || die "--output requires a file path"
        OUTPUT_FILE=$2
        shift 2
        ;;
      --ssh-timeout)
        [ $# -ge 2 ] || die "--ssh-timeout requires a number"
        SSH_TIMEOUT=$2
        shift 2
        ;;
      --no-reset | --non-destructive)
        ENABLE_RESET=0
        shift
        ;;
      --reset)
        ENABLE_RESET=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --batch)
        BATCH_MODE=1
        shift
        ;;
      --sudo-password-file)
        [ $# -ge 2 ] || die "--sudo-password-file requires a file path"
        SUDO_PASSWORD_FILE=$2
        [ -f "$SUDO_PASSWORD_FILE" ] || die "sudo password file not found: $SUDO_PASSWORD_FILE"
        shift 2
        ;;
      --keep-remote)
        KEEP_REMOTE=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [ -z "$HOST" ]; then
          HOST=$1
          shift
        else
          die "unexpected extra argument: $1"
        fi
        ;;
    esac
  done

  [ -n "$HOST" ] || die "missing target host; pass --host <alias> or provide host name"
}

resolve_config() {
  if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || die "config file not found: $CONFIG_FILE"
  elif [ -f "$REPO_ROOT/scripts/satellite.local.conf" ]; then
    CONFIG_FILE="$REPO_ROOT/scripts/satellite.local.conf"
  elif [ -f "$REPO_ROOT/scripts/satellite.example.conf" ]; then
    CONFIG_FILE="$REPO_ROOT/scripts/satellite.example.conf"
  else
    die "no satellite config found in scripts/"
  fi
}

ssh_opts() {
  printf '%s' "-o ConnectTimeout=$SSH_TIMEOUT -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new"
}

# run_ssh_tty is for the long steps. With a terminal on stdin (and not --batch)
# it forces a remote terminal so sudo can ask for a password; otherwise it is a
# plain ssh.
run_ssh_tty() {
  local opts
  opts=$(ssh_opts)
  if [ "$BATCH_MODE" != 1 ] && [ -t 0 ]; then
    # shellcheck disable=SC2086,SC2029
    ssh -tt $opts "$HOST" "$@"
  else
    # shellcheck disable=SC2086,SC2029
    ssh $opts "$HOST" "$@"
  fi
}

# remote_env prefixes remote commands so the sudo shim comes first on PATH.
remote_env() {
  if [ -n "$SUDO_PASSWORD_FILE" ]; then
    # shellcheck disable=SC2016
    printf 'PATH=%s/shim:$PATH ' "$1"
  fi
}

check_reachability() {
  local opts
  opts=$(ssh_opts)
  # shellcheck disable=SC2086
  if ssh $opts -o BatchMode=yes "$HOST" true >/dev/null 2>&1; then
    printf 'reachable'
  else
    printf 'unreachable'
  fi
}

query_disk_space() {
  local opts
  opts=$(ssh_opts)
  # shellcheck disable=SC2086
  ssh $opts -o BatchMode=yes "$HOST" "df -h / | tail -n 1 | awk '{print \$4}'" 2>/dev/null || printf 'unknown'
}

# Transfer scripts bundle to remote host via tar over SSH
deploy_scripts() {
  local opts remote_dir
  opts=$(ssh_opts)
  log "creating temporary working directory on $HOST"
  # shellcheck disable=SC2086
  remote_dir=$(ssh $opts "$HOST" "mktemp -d /tmp/runnerup-loop.XXXXXX")
  [ -n "$remote_dir" ] || die "failed to create temporary directory on $HOST"

  log "transferring scripts to $HOST:$remote_dir"
  local config_basename
  config_basename=$(basename "$CONFIG_FILE")

  # Create tar stream on controller and untar on target
  # shellcheck disable=SC2086,SC2029
  (
    cd "$REPO_ROOT"
    tar -czf - scripts/reset-satellite.sh scripts/launch-satellite.sh
  ) | ssh $opts "$HOST" "tar -xzf - -C $remote_dir"

  # Copy config file
  # shellcheck disable=SC2086,SC2029
  (
    cd "$(dirname "$CONFIG_FILE")"
    tar -czf - "$config_basename"
  ) | ssh $opts "$HOST" "tar -xzf - -C $remote_dir"

  # Copy optional local env file if present
  local env_file="${CONFIG_FILE%.conf}.env"
  if [ -f "$env_file" ]; then
    local env_basename
    env_basename=$(basename "$env_file")
    # shellcheck disable=SC2086,SC2029
    (
      cd "$(dirname "$env_file")"
      tar -czf - "$env_basename"
    ) | ssh $opts "$HOST" "tar -xzf - -C $remote_dir"
  fi

  if [ -n "$SUDO_PASSWORD_FILE" ]; then
    # A sudo shim that answers the password prompt from a file in the
    # temporary directory, so unattended runs can use sudo without a terminal.
    # shellcheck disable=SC2086,SC2029
    ssh $opts "$HOST" "umask 077; mkdir -p $remote_dir/shim; cat > $remote_dir/shim/pw" < "$SUDO_PASSWORD_FILE"
    # shellcheck disable=SC2086,SC2029
    ssh $opts "$HOST" "cat > $remote_dir/shim/sudo; chmod 700 $remote_dir/shim/sudo" <<'SHIM'
#!/bin/sh
[ "$1" = "-n" ] && shift
exec /usr/bin/sudo -S -p '' "$@" < "$(dirname "$0")/pw"
SHIM
  fi

  printf '%s' "$remote_dir"
}

cleanup_remote() {
  local remote_dir=$1
  if [ -n "$SUDO_PASSWORD_FILE" ]; then
    # shellcheck disable=SC2086,SC2029
    local cleanup_opts
    cleanup_opts=$(ssh_opts)
    # shellcheck disable=SC2086,SC2029
    ssh $cleanup_opts "$HOST" "rm -rf $remote_dir/shim" 2>/dev/null || true
  fi
  if [ "$KEEP_REMOTE" = 1 ]; then
    log "keeping remote directory $HOST:$remote_dir"
    return 0
  fi
  local opts
  opts=$(ssh_opts)
  # shellcheck disable=SC2086,SC2029
  ssh $opts "$HOST" "rm -rf $remote_dir" 2>/dev/null || true
}

# Extract failing step name and tail from output log
extract_failure() {
  local log_file=$1
  local last_step="unknown"
  local step_line
  while IFS= read -r step_line; do
    if [[ "$step_line" =~ ^---\ (.*)\ ---$ ]]; then
      last_step="${BASH_REMATCH[1]}"
    fi
  done < "$log_file"

  printf '%s\n' "$last_step"
}

# Identify which steps succeeded from log
parse_step_status() {
  local log_file=$1 step_name=$2
  if grep -q "^--- $step_name ---" "$log_file"; then
    # Step was entered
    if grep -q "MANUAL_STEP_STOP: $step_name" "$log_file"; then
      printf 'MANUAL_STOP'
    else
      printf 'PASS'
    fi
  else
    printf 'SKIPPED'
  fi
}

main() {
  parse_args "$@"
  resolve_config

  log "starting reset-loop for host: $HOST"
  log "rounds: $ROUNDS, dry-run: $DRY_RUN, config: $CONFIG_FILE"
  log "results file: $OUTPUT_FILE"

  mkdir -p "$(dirname "$OUTPUT_FILE")"
  local logs_dir
  logs_dir="$(dirname "$OUTPUT_FILE")/reset-loop-logs"
  mkdir -p "$logs_dir"

  # Check pre-flight reachability
  local initial_reachability
  initial_reachability=$(check_reachability)
  if [ "$initial_reachability" != "reachable" ]; then
    die "host $HOST is unreachable over SSH (connect timeout ${SSH_TIMEOUT}s). Ensure host is online and SSH key is trusted."
  fi
  log "host $HOST is reachable over SSH"

  local initial_disk
  initial_disk=$(query_disk_space)
  log "host $HOST available disk on /: $initial_disk"

  # Initialize results tracking arrays
  local round_num=1
  local total_passed=0
  local total_failed=0
  local total_manual_stops=0

  # Temporary storage for markdown rows
  local rows_file
  rows_file=$(mktemp /tmp/reset-loop-rows.XXXXXX)
  local details_file
  details_file=$(mktemp /tmp/reset-loop-details.XXXXXX)

  while [ "$round_num" -le "$ROUNDS" ]; do
    step_hdr "Round $round_num of $ROUNDS against $HOST"
    local r_start
    r_start=$(date +%s)
    local round_log="$logs_dir/round-${round_num}.log"
    : > "$round_log"

    # 1. Deploy bundle to remote host
    local remote_dir
    remote_dir=$(deploy_scripts)
    local config_name
    config_name=$(basename "$CONFIG_FILE")
    local remote_config="$remote_dir/$config_name"
    local opts
    opts=$(ssh_opts)

    local reset_status="PASS"
    local launch_status="PASS"
    local failure_step="none"
    local failure_tail=""
    local round_manual_stops=0

    # 2. Execute Reset (if enabled)
    local reset_duration=0
    local post_reset_reach="reachable"
    if [ "$ENABLE_RESET" = 1 ]; then
      log "Round $round_num: executing reset-satellite (destructive test-bed mode)"
      local reset_start
      reset_start=$(date +%s)
      local reset_flags=""
      if [ "$DRY_RUN" = 1 ]; then
        reset_flags="--dry-run"
      else
        reset_flags="--yes"
      fi

      # Run reset script on target
      set +e
      run_ssh_tty "$(remote_env "$remote_dir")bash $remote_dir/scripts/reset-satellite.sh $reset_flags --config $remote_config" 2>&1 | tee -a "$round_log" >&2
      local reset_rc=${PIPESTATUS[0]}
      set -e
      reset_duration=$(( $(date +%s) - reset_start ))

      if [ "$reset_rc" -eq 10 ]; then
        log "Round $round_num: reset stopped at a manual step; nothing was deleted: $(grep 'MANUAL_STEP_STOP:' "$round_log" | tail -n 1 | sed 's/.*MANUAL_STEP_STOP: //')"
        reset_status="MANUAL_STOP"
        failure_step="Reset (manual step)"
        total_manual_stops=$(( total_manual_stops + 1 ))
      elif [ "$reset_rc" -ne 0 ]; then
        log "Round $round_num: reset failed with code $reset_rc"
        reset_status="FAIL"
        failure_step="Reset"
      else
        log "Round $round_num: reset completed in ${reset_duration}s"
      fi

      # Check reachability after reset
      post_reset_reach=$(check_reachability)
      log "Round $round_num: post-reset reachability: $post_reset_reach"
      if [ "$post_reset_reach" != "reachable" ]; then
        reset_status="FAIL"
        failure_step="Reachability (after reset)"
      fi
    else
      log "Round $round_num: non-destructive lifecycle mode (--no-reset); host remains intact"
      reset_status="SKIP"
    fi

    # 3. Execute Launch if reset succeeded
    local launch_duration=0
    local step_nix="SKIP"
    local step_brew="SKIP"
    local step_dot="SKIP"
    local step_tools="SKIP"
    local step_accounts="SKIP"
    local step_fm="SKIP"
    local step_tailnet="SKIP"
    local step_runner="SKIP"

    if [ "$reset_status" = "PASS" ] || [ "$reset_status" = "SKIP" ]; then
      log "Round $round_num: executing launch-satellite"
      local launch_start
      launch_start=$(date +%s)

      local launch_flags=""
      if [ "$DRY_RUN" = 1 ]; then
        launch_flags="--dry-run --config $remote_config"
      else
        launch_flags="--yes --stop-on-manual --config $remote_config"
      fi

      # Loop on launch to handle manual sign-in stops gracefully
      local launch_done=0
      while [ "$launch_done" -eq 0 ]; do
        set +e
        run_ssh_tty "$(remote_env "$remote_dir")bash $remote_dir/scripts/launch-satellite.sh $launch_flags" 2>&1 | tee -a "$round_log" >&2
        local launch_rc=${PIPESTATUS[0]}
        set -e

        if [ "$launch_rc" -eq 0 ]; then
          launch_done=1
          launch_status="PASS"
        elif [ "$launch_rc" -eq 10 ]; then
          # Manual sign-in required
          round_manual_stops=$(( round_manual_stops + 1 ))
          total_manual_stops=$(( total_manual_stops + 1 ))

          local stopped_step
          stopped_step=$(grep "MANUAL_STEP_STOP:" "$round_log" | tail -n 1 | sed 's/.*MANUAL_STEP_STOP: //')
          log "Round $round_num: MANUAL-STEP STOP detected: $stopped_step"

          if [ "$BATCH_MODE" = 1 ]; then
            log "Round $round_num: batch mode enabled; stopping round at manual step: $stopped_step"
            launch_status="MANUAL_STOP ($stopped_step)"
            launch_done=1
          else
            printf '\n=======================================================\n'
            printf 'MANUAL ACTION REQUIRED ON %s:\n' "$HOST"
            printf '  %s\n' "$stopped_step"
            printf 'Please complete the authentication, then press [ENTER] to continue...\n'
            printf '=======================================================\n'
            read -r || true
            log "operator indicated sign-in complete; resuming launch..."
          fi
        else
          launch_done=1
          launch_status="FAIL"
          failure_step=$(extract_failure "$round_log")
          log "Round $round_num: launch failed at step: $failure_step (exit code $launch_rc)"
        fi
      done

      launch_duration=$(( $(date +%s) - launch_start ))

      # Parse individual step results
      step_nix=$(parse_step_status "$round_log" "Nix")
      step_brew=$(parse_step_status "$round_log" "Homebrew")
      step_dot=$(parse_step_status "$round_log" "Dotfiles")
      step_tools=$(parse_step_status "$round_log" "Tools")
      step_accounts=$(parse_step_status "$round_log" "Accounts")
      step_fm=$(parse_step_status "$round_log" "Firstmate home")
      step_tailnet=$(parse_step_status "$round_log" "Tailnet short name")
      step_runner=$(parse_step_status "$round_log" "runner-up place")
    fi

    # 4. Check post-launch reachability
    local post_launch_reach
    post_launch_reach=$(check_reachability)

    # 5. Measure round metrics and disk
    local r_end
    r_end=$(date +%s)
    local r_duration=$(( r_end - r_start ))
    local current_disk
    current_disk=$(query_disk_space)
    log "Round $round_num free disk on /: $current_disk"

    cleanup_remote "$remote_dir"

    # Evaluate overall round status
    local overall_result="PASS"
    if [ "$reset_status" = "MANUAL_STOP" ]; then
      overall_result="MANUAL_STOP"
    elif [ "$reset_status" = "FAIL" ] || [ "$launch_status" = "FAIL" ] || [ "$post_launch_reach" != "reachable" ]; then
      overall_result="FAIL"
      total_failed=$(( total_failed + 1 ))
      if [ -f "$round_log" ]; then
        failure_tail=$(tail -n 25 "$round_log" | sed 's/^/    /')
      fi
    else
      total_passed=$(( total_passed + 1 ))
    fi

    log "Round $round_num result: $overall_result (total: ${r_duration}s, reset: ${reset_duration}s, launch: ${launch_duration}s, reachable: $post_launch_reach)"

    # Record row
    printf '| %d | %ds | %ds | %ds | %s | %s | %s | %s | %s | %s | %s | %s | %s | **%s** |\n' \
      "$round_num" "$r_duration" "$reset_duration" "$launch_duration" "$post_launch_reach" \
      "$step_nix" "$step_brew" "$step_dot" "$step_tools" "$step_accounts" "$step_fm" "$step_tailnet" "$step_runner" "$overall_result" >> "$rows_file"

    # Record failure detail if failed
    if [ "$overall_result" = "FAIL" ]; then
      {
        printf '### Round %d Failure Details\n\n' "$round_num"
        printf -- "- **Failing Step**: \`%s\`\n" "$failure_step"
        printf -- "- **Post-Reset Reachable**: \`%s\`\n" "$post_reset_reach"
        printf -- "- **Post-Launch Reachable**: \`%s\`\n" "$post_launch_reach"
        printf -- "- **Log Tail**:\n\`\`\`\n%s\n\`\`\`\n\n" "$failure_tail"
      } >> "$details_file"
    fi

    round_num=$(( round_num + 1 ))
  done

  # Generate Final Markdown Report
  local final_disk
  final_disk=$(query_disk_space)
  local report_time
  report_time=$(date -u +"%Y-%m-%d %H:%M:%SZ")

  {
    cat <<EOF
# Satellite Reset & Launch Loop Results

Repeated reset and launch driver test results for validating host recovery and deployment reliability.

- **Target Host**: \`$HOST\`
- **Date**: $report_time
- **Total Rounds**: $ROUNDS
- **Mode**: $([ "$ENABLE_RESET" = 1 ] && printf 'Destructive Reset Loop (Test-Bed)' || printf 'Non-Destructive Lifecycle (Host Intact)') $([ "$DRY_RUN" = 1 ] && printf '[Dry-Run]' || printf '[Live Run]')
- **Summary**: $total_passed passed, $total_failed failed, $total_manual_stops manual-step stops
- **Initial Free Disk**: \`$initial_disk\` | **Final Free Disk**: \`$final_disk\`

## Results Table

| Round | Duration | Reset | Launch | Reachable | Nix | Brew | Dotfiles | Tools | Accounts | Firstmate | Tailnet | Runner-Up | Result |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
EOF
    cat "$rows_file"
    printf '\n'

    if [ -s "$details_file" ]; then
      printf '## Failure Diagnostics\n\n'
      cat "$details_file"
    fi

    cat <<EOF
## Non-Automatable Steps

The following launch steps cannot be fully automated unattended because they require interactive authentication:

| Step | Operation | Why It Requires a Human | How It Is Handled |
| --- | --- | --- | --- |
| **GitHub** | \`gh auth login\` | Requires OAuth browser authorization or device code confirmation when no \`GH_TOKEN\` is present. | Pauses as \`MANUAL_STOP\`; loop continues once auth is verified. |
| **Tailscale** | \`tailscale up\` | Requires interactive web browser SSO login unless an auth key (\`tskey-auth-...\`) is configured. | Checks status; pauses if unauthenticated until node is connected. |
| **Claude** | \`claude /login\` | Requires web browser authentication with Anthropic unless \`ANTHROPIC_API_KEY\` is set in env. | Pauses with sign-in prompt; resumes after credentials exist. |
| **Pi** | \`pi /login\` | Requires interactive browser or API token authorization. | Pauses with sign-in prompt; resumes after sign-in. |

All other steps (Hostname, Nix, Homebrew, Dotfiles, Tools installation, Firstmate fleet setup, Tailnet hostname assignment, and runner-up registration) execute fully non-interactively without prompting.
EOF
  } > "$OUTPUT_FILE"

  rm -f "$rows_file" "$details_file"
  log "results table written to: $OUTPUT_FILE"
}

main "$@"
