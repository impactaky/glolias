# glolias

`glolias` provides global aliases as real `PATH`-resident shims.

Instead of relying on shell aliases from `.bashrc` or `.zshrc`, `glolias` creates
symlinks such as `gh`, `gs`, or any other alias name in a shims directory. Those
symlinks point at one dispatcher binary. When invoked through a shim, the binary
uses `argv[0]` to decide which alias was called and then `exec`s the configured
command.

This works in contexts that call commands directly with `execvp`, including
scripts, GUI apps, IDEs, and tools that never source your shell startup files.

## Quick Start

Install the latest GitHub Release with
[mise's GitHub backend](https://mise.jdx.dev/dev-tools/backends/github.html),
then add the glolias Shims directory to future sessions:

```sh
mise use --global github:impactaky/glolias

glolias setup
glolias setup --apply

# setup affects future sessions; make the Shims available in this shell too.
export PATH="$(glolias path):$PATH"
```

For example, seal a 1Password service-account token and use it only when the
global `gh` Alias enters `op run`:

```sh
glolias credential set 1password OP_SERVICE_ACCOUNT_TOKEN
# Enter the current service-account token at the hidden /dev/tty prompt.

glolias add --credential 1password gh \
  op run --no-masking -- "$SHELFFILES/result/bin/gh"

gh auth status
```

Now any process that resolves `gh` through the glolias Shims directory executes:

```sh
op run --no-masking -- "$SHELFFILES/result/bin/gh" <original gh arguments...>
```

The `1password` Credential overwrites `OP_SERVICE_ACCOUNT_TOKEN` before `op`
starts. The generated config contains only public metadata and the Binding:

```toml
version = 2

[credentials]
1password = "OP_SERVICE_ACCOUNT_TOKEN"

[aliases]
gh.tokens = ["op", "run", "--no-masking", "--", "/absolute/path/to/real/gh"]
gh.credentials = ["1password"]
```

The service-account token itself is stored only in the personalized Credential
Runner. To rotate it, run the same command and enter the new value:

```sh
glolias credential set 1password OP_SERVICE_ACCOUNT_TOKEN
```

Bindings do not change, and the next `gh` invocation sees the new value even
when its caller is a long-lived agent with an old ambient token. Original
arguments are appended as arguments, not re-parsed as shell text, so quoting is
preserved. The real `gh` path is expanded when `glolias add` runs and avoids
recursing back through the `gh` Shim.

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

Config TOML is parsed by the MIT-licensed `tomlc17` C17 library, vendored and
pinned under [`vendor/tomlc17`](./vendor/tomlc17/PROVENANCE.md), with its
[license](./vendor/tomlc17/LICENSE) alongside the source. Its C source is
compiled directly into the binary, so no system or shared tomlc17 installation
is needed. glolias owns schema validation and canonical serialization. CLI
argument parsing uses `zig-clap`, fetched by Zig from `build.zig.zon`.

## Install

The recommended installation path is mise's GitHub backend. It selects the
matching Linux or macOS archive from the latest GitHub Release and exposes
`glolias` on mise's managed `PATH`:

```sh
mise use --global github:impactaky/glolias
```

Then preview and apply the separate persistent Shims-directory setup:

```sh
glolias setup
glolias setup --apply
```

For manual installation, release version 2.0.0 provides these archives:

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
grep 'glolias-v2.0.0-linux-x86_64.tar.gz$' SHA256SUMS | sha256sum --check -

# macOS
grep 'glolias-v2.0.0-macos-aarch64.tar.gz$' SHA256SUMS | shasum -a 256 --check
```

Extract it, place `glolias` at a stable user-selected location already on
`PATH`, and then preview persistent setup:

```sh
tar -xzf glolias-v2.0.0-linux-x86_64.tar.gz
mkdir -p "$HOME/.local/bin"
install -m 0755 glolias "$HOME/.local/bin/glolias"

glolias setup
glolias setup --apply
```

Installation, `add`, `remove`, `sync`, and dispatch never run setup implicitly.
There is no project-owned network installer or `curl | sh` path.

Default paths:

- Config: `${XDG_CONFIG_HOME:-~/.config}/glolias/config.toml`
- Shims directory: `${XDG_DATA_HOME:-~/.local/share}/glolias/shims`
- Credential Runners: `${XDG_DATA_HOME:-~/.local/share}/glolias/credentials/<credential>`

Set `XDG_DATA_HOME` to move the Shims directory. The config stays portable and
does not store the expanded path. As shown in the Quick Start, it stores public
metadata and Bindings only—never a secret, encryption key, nonce, ciphertext,
or Runner-private material. Version-1 config loads as Aliases with no Credential
Bindings; reading or dispatching does not rewrite it. The next successful
mutation serializes version 2.

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
glolias add [--force] [--credential <credential>]... <name> <command> [args...]
glolias credential set [--force] <credential> <ENV_NAME>
glolias credential attach <credential> <alias>...
glolias credential detach <credential> <alias>...
glolias credential list
glolias credential remove <credential>
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
glolias add --credential op op op
glolias add gs git -c color.ui=always status
```

Only flags before `<name>` are parsed by `glolias`. Tokens after the alias name
are stored verbatim, so leading-dash command arguments are safe.

Re-adding the same tokens succeeds. Replacing different tokens requires
`--force`:

```sh
glolias add --force gh gh --default
```

`--credential` is repeatable and every named Credential must already exist.
Creation commits the Alias and its complete ordered Binding list as one config
mutation. With `--force`, the resulting Bindings are exactly the flags supplied;
omitting every `--credential` clears previous Bindings.

Alias names must match `[A-Za-z0-9_][A-Za-z0-9_-]*`; `glolias` is reserved.
Names containing `.`, Unicode, whitespace, `:`, `/`, or other characters
outside that ASCII form are rejected. Quoted TOML keys are not supported.

### `credential set`

Creates or rotates a named Credential Runner. The value is read only from
`/dev/tty`, never argv, normal stdin, the environment, config, or a provider
command. TTY echo is disabled during entry and restored on success, failure, or
handled interruption. Empty values, NUL, and values over 8192 bytes are refused.

```sh
ssh host
glolias credential set op OP_SERVICE_ACCOUNT_TOKEN
```

Rotation is atomic and preserves every Alias Binding. Changing the public
environment-variable name requires `--force`; rotating only the value does not.
The installed Runner is owner-readable/executable and not writable (`0500`).
Credential names match `[A-Za-z0-9_][A-Za-z0-9_-]*`; environment names match
the portable `[A-Za-z_][A-Za-z0-9_]*` contract.

### `credential attach` and `credential detach`

`attach` adds the existing Credential to each existing Alias; `detach` removes
only those Bindings. These operations update config atomically, do not prompt,
and never rewrite or remove the shared Runner.

```sh
glolias credential attach op gh release-tool
glolias credential detach op release-tool
```

### `credential list`

Lists only Credential name, environment-variable name, bound Alias names, and
safe Runner status (`valid`, `stale`, or a structural error). It never displays
a value or any ciphertext/key material. There is deliberately no `credential
get`, secret-showing `show`, or `export` command.

### `credential remove`

Refuses while any Alias remains bound. Once unused, it removes metadata and the
Runner but never removes Aliases or Shims. Recovery then requires running
`credential set` and entering the value again.

Management commands preflight referenced objects and target types before their
first mutation, and each individual config or Runner replacement is atomic. A
single rename cannot cover both config and a Runner: a process or machine crash
at that boundary can leave a harmless orphan Runner. `doctor` reports it without
removing it; no command treats an orphan as an authorized Credential.

### `sync`

Recreates missing shim symlinks, repoints stale or dangling symlinks at the
current binary, and prunes orphan symlinks that no longer have a config entry.
It also atomically refreshes structurally valid Credential Runners onto the
current glolias executable while preserving their trailers. A missing, corrupt,
or identity-mismatched Runner cannot be reconstructed and requires `credential
set`; Sync never invents a value or runs open.

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
- Whether each Credential Runner is regular, executable, structurally valid,
  identity-matched, and based on the current binary
- Whether Bindings dangle or an Alias binds multiple Credentials that provide
  the same environment-variable name
- Whether the credentials directory contains orphan artifacts

`doctor` runs every check that remains possible after an error and reports all
inconsistencies found. It exits `0` for a healthy setup and `1` if it finds one
or more inconsistencies, making it suitable for scripts. Reported shim
inconsistencies include guidance to run `glolias sync`; a blocking regular file
or directory must be removed first.

The command does not repair shims or Runners or change config or `PATH`. It reports only
the environment of the shell that runs it. GUI-launched applications and IDEs
may have a different `PATH`.

When the Shims directory is missing from current `PATH`, `doctor` points to
`glolias setup` as a preview command; it never reads or repairs setup files.

## Dispatch Behavior

When invoked as `glolias`, the binary runs the management CLI.

When invoked through any other basename, for example `gh`, the binary treats that
basename as the alias name:

1. Load and validate config and the complete ordered Credential Binding list,
   including rejecting duplicate environment-variable providers.
2. For a bound Alias, validate every Runner before executing any of them. Then
   `execv` the first Runner; each Runner authenticates the configured identity
   and internal Chain state, overwrites its environment value, and `execv`s the
   next Runner or dispatcher.
3. Caller-supplied stale chain/guard variables cannot authorize or skip initial
   injection. Missing, stale, malformed, tampered, unsupported, mismatched, or
   unauthorized Runners fail closed before the Alias command starts.
4. After the Chain, use the name-scoped `GLOLIAS_GUARD` to break ordinary Alias
   recursion and resolve the Real command while skipping the Shims directory.
5. Build `argv` as `configured_tokens ++ original_args` and replace the process
   image with `execvp`.

Every Chain transition and final dispatch uses `exec`; glolias never forks and
waits. Exit codes, stdin, stdout, stderr, cwd, TTY, argument boundaries, signals,
and the final process identity therefore belong to the real command. Direct Real
command execution and unbound Shims receive no new Credential from glolias.

Exit behavior for shim-side failures follows shell conventions:

- Command not found: `127`
- Command present but not executable: `126`
- Missing config, invalid config, or shim with no config entry: `127`
- Credential config, Runner, authentication, or Chain refusal: `127` without
  running the Alias command or falling back to an ambient value

## Credential migration and rotation

For an existing ambient token, perform the one-time migration from an SSH TTY:

1. Run `glolias credential set <name> <ENV_NAME>` and paste the current value at
   the hidden prompt.
2. Attach it with `glolias credential attach <name> <alias>...`, or replace an
   Alias with `glolias add --force --credential <name> ...`.
3. Verify with `glolias doctor` and the bound command.
4. Remove the shell-profile export yourself, then restart already-running agents
   once. Glolias never edits token exports, shell profiles, or system config as
   part of Credential management.

For later rotation, run the same `credential set` command from any SSH TTY and
enter the new value. Bindings remain unchanged, and the next invocation observes
the new value without restarting its caller. After upgrading or moving glolias,
run `glolias sync` to refresh valid Runners to the installed executable.

## Credential security boundary

A Credential Runner is a personalized copy of glolias with a self-delimiting,
versioned trailer. The value is protected with fresh OS randomness and an
authenticated standard-library construction; recovery material is split/masked
inside the same artifact, and generation rejects any Runner whose raw bytes
contain the plaintext sequence. Config and ordinary management output contain no
secret material.

This is obfuscation and a review boundary, not cryptographic protection from the
same Unix user. The intended agent sandbox makes config and the credentials
directory readable/executable but not writable. Under that policy, ordinary
`env`, `cat`, `strings`, direct Real-command execution, and unbound Shims do not
reveal or receive the value. A determined same-user actor may still extract it
through binary analysis or modification, debugging, or process-memory
inspection. Glolias cannot enforce the external read-only policy and provides no
daemon, keychain, GPG, Secret Service, root/systemd service, provider stdout,
runtime Zig compiler, export API, or shell-profile mutation.

Runners append bytes without parsing ELF or Mach-O. Current release packaging
does not code-sign. Modifying a future signed/notarized macOS executable would
invalidate its signature, so such artifacts require revisiting the Runner format.

## Release packaging

On Linux, the local release entry point validates the requested version against
`build.zig.zon`, cross-builds all four targets, and writes four archives plus
`SHA256SUMS`:

```sh
scripts/package-release.sh 2.0.0 /tmp/glolias-release
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
- [docs/adr/0010-named-sealed-credential-runners.md](./docs/adr/0010-named-sealed-credential-runners.md)

Current scope:

- Linux x86-64/AArch64 and macOS 14+ Intel/Apple silicon
- Machine-managed TOML config; comments and custom formatting are not preserved
- Prefix-only Aliases: no positional placeholders or interior `$@` expansion
- Persistent setup is explicit, preview-first, user-owned, and never changes the current session
