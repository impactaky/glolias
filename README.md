# glolias

`glolias` provides global aliases as real `PATH`-resident shims.

Instead of relying on shell aliases from `.bashrc` or `.zshrc`, `glolias` creates
symlinks such as `gh`, `gs`, or any other alias name in a shims directory. Those
symlinks point at one dispatcher binary. When invoked through a shim, the binary
uses `argv[0]` to decide which alias was called and then `exec`s the configured
command.

This works in contexts that call commands directly with `execvp`, including
scripts, GUI apps, IDEs, and tools that never source your shell startup files.

## Example

```sh
zig build -Doptimize=ReleaseFast

./zig-out/bin/glolias add gh op plugin run -- gh
./zig-out/bin/glolias add gs git status

export PATH="$(./zig-out/bin/glolias path):$PATH"

gh pr status
gs
```

The first command above stores:

```toml
[aliases]
gh = ["op", "plugin", "run", "--", "gh"]
```

Then running:

```sh
gh pr status
```

execs:

```sh
op plugin run -- gh pr status
```

Original arguments are appended as arguments, not re-parsed as shell text, so
quoting is preserved.

## Build

Building from source requires Zig 0.16 on Linux or macOS:

```sh
zig build
```

The native binary is written to `zig-out/bin/glolias`. Run the test suites with:

```sh
zig build test                 # unit tests
git submodule update --init    # first time only
zig build e2e                  # end-to-end tests with Bats
```

The project includes a small internal TOML subset parser for the machine-managed
config schema. CLI argument parsing uses `zig-clap`, fetched by Zig from
`build.zig.zon`.

## Install

Release version 0.2.0 provides these archives:

| Archive suffix | Runtime baseline |
| --- | --- |
| `linux-x86_64` | static musl, x86-64 Linux |
| `linux-aarch64` | static musl, AArch64 Linux |
| `macos-x86_64` | macOS 14 or later, Intel |
| `macos-aarch64` | macOS 14 or later, Apple silicon |

Download the archive for your platform together with `SHA256SUMS` from the
GitHub Release. Verify the selected archive before extracting it. For example:

```sh
# Linux
grep 'glolias-v0.2.0-linux-x86_64.tar.gz$' SHA256SUMS | sha256sum --check -

# macOS
grep 'glolias-v0.2.0-macos-aarch64.tar.gz$' SHA256SUMS | shasum -a 256 --check
```

Extract it, place `glolias` at a stable user-selected location already on
`PATH`, and then preview persistent setup:

```sh
tar -xzf glolias-v0.2.0-linux-x86_64.tar.gz
mkdir -p "$HOME/.local/bin"
install -m 0755 glolias "$HOME/.local/bin/glolias"

glolias setup
glolias setup --apply
glolias add gh op plugin run -- gh
```

Installation, `add`, `remove`, `sync`, and dispatch never run setup implicitly.
There is no network installer or `curl | sh` path.

Default paths:

- Config: `${XDG_CONFIG_HOME:-~/.config}/glolias/config.toml`
- Shims directory: `${XDG_DATA_HOME:-~/.local/share}/glolias/shims`

Set `XDG_DATA_HOME` to move the Shims directory. The config stays portable and
does not store the expanded path:

```toml
version = 1

[aliases]
gh = ["op", "plugin", "run", "--", "gh"]
gs = ["git", "status"]
```

## Persistent setup

`setup` is preview-first and non-interactive:

```sh
glolias setup                    # preview additions; read-only
glolias setup --apply            # apply those additions
glolias setup --remove           # preview owned-state removal; read-only
glolias setup --remove --apply   # remove only owned setup state
```

Every plan prints each target path, exact managed content or removal action,
no-op, manual step, and conflict. `--apply` is the only mutation authorization.
All targets are preflighted before the first write. A conflict changes nothing;
each later file change is atomic, and a filesystem failure reports applied,
failed, and pending actions so rerunning the command converges.

Setup targets only files owned by the current user:

- `.profile` for Bash/POSIX login shells
- `.zprofile` for Zsh login shells
- `${XDG_CONFIG_HOME:-~/.config}/environment.d/60-glolias.conf` for Linux
  services started by the systemd user manager
- `~/Library/LaunchAgents/com.github.impactaky.glolias-path.plist` for future
  macOS launchd user/GUI processes

Linux `environment.d` does not cover arbitrary SSH, TTY, or non-systemd shells.
When no systemd user context is detected, or for shells other than the supported
login shells, the plan prints a concrete manual step. On macOS the LaunchAgent
uses `/bin/launchctl setenv` only when launchd starts it at a future login.

Setup never invokes `sudo`, edits system-wide paths, changes the invoking
process's `PATH`, runs `launchctl` during apply, or retroactively changes
existing applications. Start a new login/session after applying or removing.
Profile bytes outside the versioned managed block are preserved. Repeated shell
evaluation, apply, and removal are idempotent.

## Platforms

Linux and macOS share the complete Alias management and dispatch behavior.
Release Linux binaries are statically linked against musl. macOS binaries use
the native executable-path API and require macOS 14 or later. Windows is not
supported.

## Commands

```sh
glolias add [--force] <name> <command> [args...]
glolias remove <name>
glolias sync
glolias list
glolias path
glolias setup [--remove] [--apply]
glolias doctor
```

### `add`

Adds or updates an alias and creates the matching shim symlink.

```sh
glolias add gh op plugin run -- gh
glolias add gs git -c color.ui=always status
```

Only flags before `<name>` are parsed by `glolias`. Tokens after the alias name
are stored verbatim, so leading-dash command arguments are safe.

Re-adding the same tokens succeeds. Replacing different tokens requires
`--force`:

```sh
glolias add --force gh gh --default
```

Alias names must match `[A-Za-z0-9_][A-Za-z0-9_-]*`; `glolias` is reserved.
Names containing `.`, Unicode, whitespace, `:`, `/`, or other characters
outside that ASCII form are rejected. Quoted TOML keys are not supported.

### `sync`

Recreates missing shim symlinks, repoints stale or dangling symlinks at the
current binary, and prunes orphan symlinks that no longer have a config entry.

Use this after moving or reinstalling the binary, or after restoring dotfiles on
a new machine.

### `list`

Prints configured aliases sorted by name:

```text
gh	op plugin run -- gh
gs	git status
```

### `path`

Prints only the expanded absolute shims directory, suitable for shell setup:

```sh
export PATH="$(glolias path):$PATH"
```

### `remove`

Deletes an alias from the config and removes its shim:

```sh
glolias remove gs
```

Removing a missing alias is an error.

### `doctor`

Performs a read-only health check of the current shell environment:

- Whether the config exists and parses successfully
- Whether the shims path resolves to a directory
- Whether the shims directory is on `PATH`
- Whether another executable shadows a shim before the shims directory
- Whether every configured Alias has a symlink pointing at the current `glolias`
  binary (including missing, dangling, stale, or non-symlink entries)
- Whether the shims directory contains orphan symlinks with no config entry

`doctor` runs every check that remains possible after an error and reports all
inconsistencies found. It exits `0` for a healthy setup and `1` if it finds one
or more inconsistencies, making it suitable for scripts. Reported shim
inconsistencies include guidance to run `glolias sync`; a blocking regular file
or directory must be removed first.

The command does not repair shims or change config or `PATH`. It reports only
the environment of the shell that runs it. GUI-launched applications and IDEs
may have a different `PATH`.

When the Shims directory is missing from current `PATH`, `doctor` points to
`glolias setup` as a preview command; it never reads or repairs setup files.

## Dispatch Behavior

When invoked as `glolias`, the binary runs the management CLI.

When invoked through any other basename, for example `gh`, the binary treats that
basename as the alias name:

1. Load the config.
2. If `GLOLIAS_GUARD` already contains the alias name, resolve the real command
   by searching `PATH` while skipping the configured shims directory.
3. Otherwise, add the alias name to `GLOLIAS_GUARD`.
4. Build `argv` as `configured_tokens ++ original_args`.
5. Replace the current process image with `execvp`.

Because the shim uses `exec`, it does not fork and wait. Exit codes, stdin,
stdout, stderr, cwd, environment, and signals belong to the real command.

Exit behavior for shim-side failures follows shell conventions:

- Command not found: `127`
- Command present but not executable: `126`
- Missing config, invalid config, or shim with no config entry: `127`

## Release packaging

On Linux, the local release entry point validates the requested version against
`build.zig.zon`, cross-builds all four targets, and writes four archives plus
`SHA256SUMS`:

```sh
scripts/package-release.sh 0.2.0 /tmp/glolias-release
```

Each `glolias-vX.Y.Z-<os>-<arch>.tar.gz` contains executable `glolias`,
`README.md`, and `LICENSE`. The script refuses to overwrite an existing output
and verifies the checksum file before succeeding.

`.github/workflows/release.yml` runs only for strict `vX.Y.Z` tag patterns. It
uses the same script, so a tag/build version mismatch fails before publication.
Only after all four archives and checksums pass does the workflow create the
tag's GitHub Release with generated notes. The workflow does not create or push
tags.

## Design Notes

Background and rationale are in:

- [CONTEXT.md](./CONTEXT.md)
- [docs/adr/0001-single-dispatcher-with-symlink-shims.md](./docs/adr/0001-single-dispatcher-with-symlink-shims.md)
- [docs/adr/0002-env-var-reentrancy-guard.md](./docs/adr/0002-env-var-reentrancy-guard.md)
- [docs/adr/0003-toml-machine-managed-config.md](./docs/adr/0003-toml-machine-managed-config.md)
- [docs/adr/0004-linux-first-no-environment-management.md](./docs/adr/0004-linux-first-no-environment-management.md)
- [docs/adr/0005-transparent-execv-no-fork.md](./docs/adr/0005-transparent-execv-no-fork.md)
- [docs/adr/0006-bats-e2e-suite.md](./docs/adr/0006-bats-e2e-suite.md)
- [docs/adr/0007-zig-for-the-native-dispatcher.md](./docs/adr/0007-zig-for-the-native-dispatcher.md)
- [docs/adr/0008-doctor-is-a-read-only-health-check.md](./docs/adr/0008-doctor-is-a-read-only-health-check.md)
- [docs/adr/0009-preview-first-user-environment-setup.md](./docs/adr/0009-preview-first-user-environment-setup.md)

Current scope:

- Linux x86-64/AArch64 and macOS 14+ Intel/Apple silicon
- Machine-managed TOML config; comments and custom formatting are not preserved
- Prefix-only Aliases: no positional placeholders or interior `$@` expansion
- Persistent setup is explicit, preview-first, user-owned, and never changes the current session
