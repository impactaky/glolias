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

Requirements:

- Linux
- Zig 0.16

Build:

```sh
zig build
```

The binary is written to:

```sh
zig-out/bin/glolias
```

Run tests:

```sh
zig build test                 # unit tests
git submodule update --init    # first time only
zig build e2e                  # end-to-end (bats)
```

The project includes a small internal TOML subset parser for the
machine-managed config schema. CLI argument parsing uses `zig-clap`, fetched by
Zig from `build.zig.zon`.

## Install

Copy or symlink `zig-out/bin/glolias` somewhere stable on your system, then run:

```sh
glolias add gh op plugin run -- gh
glolias path
```

Add the printed shims directory to `PATH` ahead of the real commands it should
shadow. `glolias` deliberately does not edit shell profiles, desktop session
files, or other environment configuration.

Default paths:

- Config: `${XDG_CONFIG_HOME:-~/.config}/glolias/config.toml`
- Shims: `${XDG_DATA_HOME:-~/.local/share}/glolias/shims`

Set `XDG_DATA_HOME` to move the shims directory. The config stays portable and
does not store the expanded shims path:

```toml
version = 1

[aliases]
gh = ["op", "plugin", "run", "--", "gh"]
gs = ["git", "status"]
```

## Commands

```sh
glolias add [--force] <name> <command> [args...]
glolias remove <name>
glolias sync
glolias list
glolias path
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

Invalid alias names are rejected: `glolias`, empty names, names containing `/`,
and names beginning with `-`.

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

Checks the current shell environment:

- Config parse status
- Whether the shims directory exists
- Whether the shims directory is on `PATH`
- Whether another executable shadows a shim before the shims directory
- Orphan symlinks

`doctor` reports only the environment of the shell that runs it. GUI-launched
applications and IDEs may have a different `PATH`.

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

## Design Notes

Background and rationale are in:

- [CONTEXT.md](./CONTEXT.md)
- [docs/adr/0001-single-dispatcher-with-symlink-shims.md](./docs/adr/0001-single-dispatcher-with-symlink-shims.md)
- [docs/adr/0002-env-var-reentrancy-guard.md](./docs/adr/0002-env-var-reentrancy-guard.md)
- [docs/adr/0003-toml-machine-managed-config.md](./docs/adr/0003-toml-machine-managed-config.md)
- [docs/adr/0004-linux-first-no-environment-management.md](./docs/adr/0004-linux-first-no-environment-management.md)
- [docs/adr/0005-transparent-execv-no-fork.md](./docs/adr/0005-transparent-execv-no-fork.md)

Current scope:

- Linux first
- Machine-managed TOML config; comments and custom formatting are not preserved
- Prefix-only aliases: no positional placeholders or interior `$@` expansion
- `glolias` does not modify your shell, desktop, or IDE environment
