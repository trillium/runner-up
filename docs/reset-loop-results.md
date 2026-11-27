# Satellite Reset & Launch Loop Results

Repeated reset and launch driver test results for validating host recovery and deployment reliability.

- **Target Host**: `mini3`
- **Output Directory**: `docs/reset-loop-logs/`
- **Driver Script**: `scripts/reset-loop.sh`
- **Reset Script**: `scripts/reset-satellite.sh` (Destructive Test-Bed Tool)
- **Launch Script**: `scripts/launch-satellite.sh` (Production Satellite Setup)

## Product Satellite vs Test-Bed Model

- **Production Satellite (Non-Destructive)**: A machine that contributes compute when idle. The host is **never destroyed**: runner-up places execute jobs inside disposable Tart VMs or containers. The machine joins the scale set pool, runs workloads in sandbox isolation, and leaves cleanly with the host system intact.
- **Test-Bed Wipe Loop (Destructive)**: Designed specifically for test machines like `mini3` to prove out bare-metal reproducibility over repeated wipes.

## Commands for mini3 and Satellites

### 1. Test-Bed Reset Loop (mini3)
To execute the first live round against `mini3` from the coordinator / controller:

```sh
# Dry run verification first (non-destructive check)
./scripts/reset-loop.sh --host mini3 --rounds 1 --dry-run

# Live destructive reset and rebuild round
./scripts/reset-loop.sh --host mini3 --rounds 1 --config scripts/satellite.local.conf
```

### 2. Primary Production Satellite Lifecycle (Non-Destructive)
To test and measure satellite spin-up and pool readiness on a machine without wiping the host:

```sh
./scripts/reset-loop.sh --host satellite-1 --no-reset --config scripts/satellite.local.conf
```

## What Spinning Up a Satellite Involves

Every satellite spin-up executes the following lifecycle phases:

| Step | Operation | Destructive? | Automatable? | Notes |
| --- | --- | --- | --- | --- |
| **Hostname** | `scutil --set HostName` | No | Automatable | Sets machine identification; requires sudo. |
| **Nix** | Official Nix installer | No | Automatable | Installs Nix daemon and synthetic APFS mount. |
| **Homebrew** | Official Homebrew installer | No | Automatable | Sets up package prefix (`/opt/homebrew`). |
| **Dotfiles** | `git clone` & installer | No | Automatable | Clones config repo and rewrites username. |
| **Tools** | Install `claude`, `pi`, `gh`, `tailscale`, `tart` | No | Automatable | CLI utilities and VM hypervisors. |
| **GitHub Login** | `gh auth login` | No | Needs Human* | OAuth browser sign-in (*automatable with `GH_TOKEN`). |
| **Tailscale Auth** | `tailscale up` | No | Needs Human* | Browser SSO login (*automatable with auth key). |
| **Claude Auth** | `claude /login` | No | Needs Human* | Browser sign-in (*automatable with `ANTHROPIC_API_KEY`). |
| **Pi Auth** | `pi /login` | No | Needs Human* | Browser sign-in (*automatable with API token). |
| **Firstmate Home**| Create `~/fm_home` hierarchy | No | Automatable | Fleet state, bin, data, config directories. |
| **Tailnet Name** | `tailscale set --hostname` | No | Automatable | Assigns stable network short name. |
| **Pool Join** | `runner-up machine add` | No | Automatable | Registers machine with coordinator over SSH. |
| **Job Execution**| runner-up runner place | No | Automatable | One-job runner runs in disposable Tart VM / container. |

## Results Table Schema

Each round executed by `scripts/reset-loop.sh` appends a row to the results table recording round duration, reset time, launch time, reachability status, and the individual pass/fail status of every launch step:

| Round | Duration | Reset | Launch | Reachable | Nix | Brew | Dotfiles | Tools | Accounts | Firstmate | Tailnet | Runner-Up | Result |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| Template | 0s | 0s | 0s | reachable | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | **PASS** |

### Step Result Definitions
- **PASS**: The step succeeded cleanly (or skipped because prerequisites were already satisfied).
- **FAIL**: The step encountered an error and exited non-zero. The log tail of the failing step is captured in the diagnostics section below.
- **MANUAL_STOP**: A human sign-in step was required (e.g., browser authentication for GitHub, Tailscale, Claude, or Pi). This is treated as a pause point, not a failure. Once the human satisfies the authentication, the loop resumes.
- **SKIP**: The step was skipped because an earlier prerequisite step failed, or reset was skipped in `--no-reset` mode.

## Non-Automatable Steps

The following launch steps require human intervention when run on a fresh machine without pre-seeded credentials:

| Step | Operation | Why It Requires a Human | How It Is Handled |
| --- | --- | --- | --- |
| **GitHub** | `gh auth login` | Requires OAuth browser authorization or device code confirmation when no `GH_TOKEN` or `GITHUB_TOKEN` is present in the environment. | Pauses as `MANUAL_STOP`; loop prompts operator and continues once authenticated. Can be automated by placing `GH_TOKEN` in `scripts/satellite.local.env`. |
| **Tailscale** | `tailscale up` | Requires interactive web browser SSO login unless an auth key (`tskey-auth-...`) is provided. | Pauses as `MANUAL_STOP` if unauthenticated. The reset script intentionally preserves existing Tailscale credentials so reconnection over Tailscale does not drop. |
| **Claude** | `claude /login` | Claude Code CLI requires browser OAuth authentication with Anthropic unless `ANTHROPIC_API_KEY` is provided. | Pauses with sign-in prompt; resumes after credentials exist. Can be automated by placing `ANTHROPIC_API_KEY` in `scripts/satellite.local.env`. |
| **Pi** | `pi /login` | Pi agent requires browser or token authentication. | Pauses with sign-in prompt; resumes after operator indicates sign-in is complete. |
