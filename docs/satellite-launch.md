# Launching a satellite

A satellite is a machine that runs the Claude and Pi agents, joins your
tailnet under a short name, keeps a firstmate home, and can also serve
runner-up places. `scripts/launch-satellite.sh` takes a bare macOS machine
(Linux is designed for but not yet tested) to that state from one small
per-machine config file.

The script does not replace `runner-up machine add`. That command runs on the
coordinator, so the script either prints the exact command for the coordinator
or, if you ask it to, runs it there over SSH.

## Quick start

```sh
cp scripts/satellite.example.conf scripts/satellite.local.conf
$EDITOR scripts/satellite.local.conf

# Print every step without changing anything.
./scripts/launch-satellite.sh --dry-run

# Run it. It stops and asks before every sudo, login and credential step.
./scripts/launch-satellite.sh
```

`scripts/satellite.local.conf` and `scripts/satellite.local.env` are ignored
by git. The example config uses placeholder hostnames and a placeholder
dotfiles repository; replace them before a real run.

## What it does, in order

| Step | What happens | Asks first? |
| --- | --- | --- |
| Hostname | `scutil` on macOS, `hostnamectl` on Linux | yes, sudo |
| Nix | the official Nix installer; `--daemon` on Linux | yes, sudo |
| Homebrew | the official Homebrew installer | yes, sudo |
| Dotfiles | clone the repo, replace the hardcoded user, run its installer | if `SATELLITE_DOTFILES_NEEDS_AUTH=1` or `SATELLITE_DOTFILES_NEEDS_SUDO=1` |
| Tools | `claude`, `pi`, `gh`, `tailscale`, `tart` | no, except Homebrew's own sudo prompt |
| Accounts | `gh auth login`, `tailscale up`, then Claude and Pi `/login` | yes, every sign-in |
| Firstmate home | create the fleet's `state`, `config`, `bin`, `data` and `.agents` folders; optional source clone and installer | if `SATELLITE_FIRSTMATE_NEEDS_AUTH=1` |
| Tailnet short name | `tailscale set --hostname NAME` | yes if Tailscale is not signed in yet |
| runner-up place | `runner-up machine add`, or the exact command for the coordinator | yes in `local` and `ssh` modes |

Most steps skip themselves when they are already done, and the dotfiles step
updates the clone and runs the installer again, so running the script again is
safe.

## Config reference

The config is a shell file of assignments, and the script sources it, so only
use a config you trust. Every setting has a default except the three required
names. The script runs as the account that invokes it and does not create
`SATELLITE_USERNAME`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `SATELLITE_HOSTNAME` | required | the machine's name |
| `SATELLITE_USERNAME` | required | the account the steps run as; also replaces the dotfiles' hardcoded user |
| `SATELLITE_TAILNET_NAME` | required | the machine's short name on the tailnet |
| `SATELLITE_OS` | `auto` | `auto`, `darwin` or `linux`; a mismatch stops the script |
| `SATELLITE_ENV_FILE` | `scripts/satellite.local.env` | an untracked file of credentials, sourced but never printed |
| `SATELLITE_DOTFILES_REPO` | empty | dotfiles repository; empty skips the step |
| `SATELLITE_DOTFILES_REF` | `main` | branch or tag to clone |
| `SATELLITE_DOTFILES_DIR` | `$HOME/.local/share/satellite-launch/dotfiles` | where the clone lives |
| `SATELLITE_DOTFILES_INSTALL` | `install.sh` | installer inside the clone; empty keeps only the clone |
| `SATELLITE_DOTFILES_INSTALL_ARGS` | empty array | arguments for the installer |
| `SATELLITE_DOTFILES_HARDCODED_USERNAME` | `trilliumsmith` | the name to replace in the clone; empty leaves it alone |
| `SATELLITE_DOTFILES_NEEDS_SUDO` | `0` | set `1` to run the installer with sudo, after asking |
| `SATELLITE_DOTFILES_NEEDS_AUTH` | `0` | set `1` when the repository is private, so git asks for credentials |
| `SATELLITE_TOOLS` | empty array | any of `claude`, `pi`, `gh`, `tailscale`, `tart` |
| `SATELLITE_TAILSCALE_INSTALL` | `cask` | `cask` for the Mac app, `formula` for the open-source daemon |
| `SATELLITE_ACCOUNTS` | empty array | any of `github`, `tailscale`, `claude`, `pi` |
| `SATELLITE_FIRSTMATE_HOME` | `$HOME/fm_home` | firstmate's home |
| `SATELLITE_FIRSTMATE_FLEET` | empty | fleet folder to create under the home |
| `SATELLITE_FIRSTMATE_REPO` | empty | optional firstmate source repository |
| `SATELLITE_FIRSTMATE_REF` | `main` | branch or tag of that source |
| `SATELLITE_FIRSTMATE_INSTALL` | empty | optional installer inside the source clone |
| `SATELLITE_FIRSTMATE_NEEDS_AUTH` | `0` | set `1` when the source repository is private |
| `SATELLITE_RUNNER_UP_MODE` | `auto` | `auto`, `off`, `print`, `local` or `ssh` |
| `SATELLITE_RUNNER_UP_COORDINATOR` | empty | the coordinator's SSH destination, used by `auto` and `ssh` |
| `SATELLITE_RUNNER_UP_MACHINE` | `SATELLITE_HOSTNAME` | the machine's name in the runner-up setup |
| `SATELLITE_RUNNER_UP_SSH` | empty | the destination the coordinator uses to reach this machine |
| `SATELLITE_RUNNER_UP_PROVIDER` | empty | `tart`, `host` or `container`; empty lets runner-up pick tart |
| `SATELLITE_RUNNER_UP_IMAGE` | empty | the tart or container image; required for tart |
| `SATELLITE_RUNNER_UP_POOLS` | empty array | pools the places serve; empty serves every pool |
| `SATELLITE_RUNNER_UP_PLACES` | `0` | number of places; `0` lets runner-up decide |
| `SATELLITE_RUNNER_UP_PLACE_CORES` | `0` | cores per place; `0` lets runner-up decide |
| `SATELLITE_RUNNER_UP_PLACE_MEMORY` | `0` | memory per place in MB; `0` lets runner-up decide |

`SATELLITE_CONFIG_DIR` is set for the config to the directory holding the
config file, so `SATELLITE_ENV_FILE="$SATELLITE_CONFIG_DIR/satellite.local.env"`
always names the file beside it.

## The dotfiles username

The dotfiles hardcode `trilliumsmith`, while a satellite may run as a different
account. Before running the installer, the script finds
every tracked text file in the clone that contains
`SATELLITE_DOTFILES_HARDCODED_USERNAME` and replaces it with
`SATELLITE_USERNAME`. The clone is disposable, so this does not touch the
dotfiles repository. Set the hardcoded name to empty to skip the rewrite.

## runner-up registration

`runner-up machine add` reads and writes the coordinator's setup file and
reaches the machine over SSH, so it must run on the coordinator. The mode
decides how the script handles that:

- `auto` (default): `print` when `SATELLITE_RUNNER_UP_COORDINATOR` is set,
  otherwise `local`.
- `off`: do nothing.
- `print`: print the exact command. Run it on the coordinator.
- `local`: run `runner-up machine add` on this machine, for a coordinator that
  is also the satellite.
- `ssh`: after asking, run the command on `SATELLITE_RUNNER_UP_COORDINATOR`
  over SSH. The coordinator needs runner-up on its `PATH` and SSH access back
  to `SATELLITE_RUNNER_UP_SSH`.

The printed command is the same one the [README](../README.md) shows, with the
configured pools, provider, image and sizes:

```sh
runner-up machine add satellite-1 --ssh ci@satellite-1 --provider tart \
    --image ghcr.io/cirruslabs/macos-sequoia-base:latest --pool mac-satellite
```

After it runs, edit the setup file so each place serves only its own pool, run
`runner-up check-config`, and restart or let the running coordinator apply the
change. See the README's [Setting up](../README.md#setting-up) section.

## Credentials

Nothing credential-like belongs in the config. Put credentials in the
untracked `scripts/satellite.local.env` (or another file named by
`SATELLITE_ENV_FILE`), or type them when the script asks:

```sh
# scripts/satellite.local.env, mode 600, ignored by git
GH_TOKEN=...
ANTHROPIC_API_KEY=...
```

The file is sourced with `set -a`, so its variables reach the tools that read
them, and the script never prints them. The script warns when the file is
readable by other users. It also refuses a config that looks like it contains a
GitHub, Anthropic or Tailscale token, and it refuses to run as root.

Every step that needs sudo, a browser sign-in or a credential calls the same
confirmation prompt. In `--dry-run` the prompt is printed instead of asked, so
a dry run never blocks and never changes the machine.

## Verifying without a machine

```sh
shellcheck scripts/launch-satellite.sh scripts/reset-satellite.sh scripts/reset-loop.sh scripts/satellite.example.conf
make lint-scripts
./scripts/launch-satellite.sh --dry-run --config scripts/satellite.example.conf
./scripts/reset-satellite.sh --dry-run
```

The dry run prints every command, including the `runner-up machine add` line,
without running anything. It needs no sudo and no network. `make lint-scripts`
runs the same ShellCheck check and says what to install when ShellCheck is
missing.

## Resetting a satellite (test-bed only)

The production design for satellites is **non-destructive**: machines borrow
idle compute, running jobs in disposable Tart VMs or containers without modifying
or wiping the host machine.

`scripts/reset-satellite.sh` is a **destructive test-bed tool** designed solely
for dedicated test machines (such as `mini3`) to prove launch script reliability
from a bare OS over repeated wiped cycles. It removes:
- **Nix**: unloads daemons, deletes the APFS `/nix` volume, cleans `/etc/synthetic.conf`, `/etc/fstab`, shell profiles, and removes `_nixbld` build users.
- **Homebrew**: removes `/opt/homebrew` (or Intel prefixes), Homebrew caches, and logs.
- **Installed tools**: stops and deletes Tart VMs and caches, removes Claude Code, Pi, and GitHub CLI config.
- **Dotfiles**: removes the cloned dotfiles repository, satellite-launch state, and resets shell dotfiles in `$HOME`.
- **Fleet folders**: removes `$SATELLITE_FIRSTMATE_HOME` (`~/fm_home`).
- **User caches and temporary files**: cleans `~/Downloads`, `~/.cache`, and test files in `/tmp`.

### Safety guarantees
- **SSH access preserved**: Never touches `~/.ssh/authorized_keys`, `known_hosts`, or user keys.
- **Tailscale preserved**: Never touches `/Applications/Tailscale.app` or Tailscale credentials/daemon so remote connection stays alive.
- **User account preserved**: Never deletes the user account itself.

By default, the script runs in dry-run mode and prints what it would remove:
```sh
./scripts/reset-satellite.sh
```

To perform the actual wipe:
```sh
./scripts/reset-satellite.sh --yes
```

## Repeatable reset and launch loop

`scripts/reset-loop.sh` drives automated reset and launch cycles over SSH from a
controller machine. It supports two modes:
1. **Non-destructive lifecycle mode (`--no-reset`)**: the primary product path.
   Measures setup time, step pass/fail, and pool registration while leaving the
   host completely intact.
2. **Destructive test-bed mode (`--reset`, default)**: wipes and rebuilds dedicated
   test beds (e.g. `mini3`) over N rounds to prove bare-metal repeatability.

Features:
- **Zero prerequisites on target**: requires only standard SSH; copies required scripts and config to a temporary remote directory using built-in `tar`.
- **Tolerant to slow/wedged hosts**: enforces configurable connection timeouts (`--ssh-timeout`, default 15s) and reachability checks before and after reset and launch.
- **Tracks step-level status**: records duration, per-step pass/fail, reachability, and failure log tails.
- **Manual-step stop handling**: human sign-ins (GitHub, Tailscale, Claude, Pi) are paused and recorded as `MANUAL_STOP` rather than failures; once satisfied, the loop resumes.
- **Markdown output**: outputs a structured results table and diagnostics to `docs/reset-loop-results.md` (or `--output`).

### Usage

```sh
# Primary non-destructive lifecycle check (leaves host intact):
./scripts/reset-loop.sh --host satellite-1 --no-reset

# Destructive test-bed loop (e.g. mini3):
./scripts/reset-loop.sh --host mini3 --rounds 3 --config scripts/satellite.local.conf

# Dry run verification:
./scripts/reset-loop.sh --host mini3 --dry-run
```

See [docs/reset-loop-results.md](reset-loop-results.md) for table results and non-automatable steps details.

## Linux

The script already branches for Linux where the commands differ: `hostnamectl`
for the hostname, `--daemon` for the Nix installer, and the same Homebrew,
dotfiles, tool and runner-up steps. The macOS-only pieces are the `tart` tool,
the Tailscale cask and the `scutil` hostname calls. Linux is a later target and
has not been run end to end.

## Troubleshooting

- **`claude` or `pi` is not found after installing.** The installers put the
  binary in `~/.local/bin`, which the script adds to `PATH`. Open a new
  terminal for the rest of the session.
- **Tailscale is installed but the CLI is not on `PATH`.** The script also
  checks `/Applications/Tailscale.app/Contents/MacOS/Tailscale`, the CLI
  inside the Mac app.
- **The dotfiles installer cannot run.** Check `SATELLITE_DOTFILES_INSTALL`
  names a file inside the clone, and set `SATELLITE_DOTFILES_NEEDS_SUDO=1` if
  the installer writes outside the home directory.
- **The coordinator cannot reach the machine.** `runner-up machine add` needs
  `ssh -o BatchMode=yes USER@MACHINE true` to work from the coordinator.
  Set `SATELLITE_RUNNER_UP_SSH` to the destination that works there.
