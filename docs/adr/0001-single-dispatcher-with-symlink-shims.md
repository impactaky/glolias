# Single dispatcher binary with symlink shims

We provide each Alias as a symlink (named e.g. `gh`) in one `PATH`-resident shims directory, all pointing at a single Zig dispatcher binary, which reads `argv[0]` to discover which Alias it is, looks the name up in a config file, and execs. We chose this over compiling a separate binary per Alias.

## Considered Options

- **Compile-per-alias** — `glolias add` invokes the Zig compiler to emit a standalone binary with the target baked in. Rejected: requires the Zig toolchain on every machine at runtime, is slow (a compile per Alias), produces N binaries to update, and a behavior change means recompiling all of them.
- **Single dispatcher + symlinks (chosen)** — one binary to ship and update; "adding an Alias" is just creating a symlink plus writing one config line (instant, no compiler). This is the established `busybox` / `pyenv` / `asdf` / `rustup` shim pattern.

## Mode detection

The single binary plays two roles, selected by `basename(argv[0])`:

- `== "glolias"` → **management mode** (`add`/`remove`/`list`/`path`/`sync`/`doctor`).
- anything else → **shim dispatch** for that name.
- empty / degenerate (`""`, `"."`, `"/"`) → hard error, exit 127 (cannot determine alias; see ADR 0002 for why `argv[0]` is the sole source).

The management name `glolias` is **fixed by contract**: the binary must be installed and invoked as `glolias`, and `glolias` is a **reserved** alias name (`add` rejects it). We deliberately did not add a `GLOLIAS_SELF_NAME` override — simplicity over flexibility. Renaming the binary disables management mode by design.

Alias names that coincide with management subcommands (e.g. an alias named `add`) are safe: mode is decided from `argv[0]` *before* any subcommand parsing, so a standalone `add` shim and `glolias add` never collide.

## Consequences

- Startup must be fast and dependency-free: the dispatcher is on the hot path of *every* shimmed command invocation.
- All Aliases share one config file; the dispatcher must resolve `argv[0]`'s basename robustly even when invoked via a symlink.
- The dispatcher also **sets** `argv[0]` for the command it execs: `tokens[0]` on a first-hit reroute, and the alias basename on a re-entrant Real-command exec — never the shim's own path.
