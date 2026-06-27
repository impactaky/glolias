# Env-var re-entrancy guard against self-shadowing recursion

A Shim shadows a command name on `PATH`, so when its reroute eventually re-invokes that same name (e.g. `gh` → `op plugin run -- gh`, and `op` then resolves `gh` via `PATH` back to the Shim), it would loop forever. We break the loop with a per-name re-entrancy guard carried in an inherited environment variable (`GLOLIAS_GUARD`, a colon-separated set of Alias names): on the first hit the Shim adds its name to the set and reroutes; on a re-entrant hit (its name already in the set) it instead resolves the Real command — a `PATH` search excluding the Shims directory — and execs that with the args it was given.

The alias name comes **solely** from `basename(argv[0])` (the symlink name as invoked). `/proc/self/exe` cannot substitute: exec-ing a symlink resolves it to the real `glolias` binary, so `/proc/self/exe` reports `glolias`, losing the alias name (this is why busybox/pyenv dispatch on `argv[0]`). An empty `argv[0]` is therefore unrecoverable and is a hard error (exit 127), not a fallback. Likewise, the Shims directory excluded from the `PATH` search is the **known XDG path** glolias owns, *not* derived from `/proc/self/exe` (which points at the install dir, not the Shims dir).

## Considered Options

- **Env-var re-entrancy guard (chosen)** — precise (suppresses only the specific re-entrant Alias, so legitimate shim-calls-another-shim chains still work), portable, and self-clearing (the marker lives only in that process subtree's environment). Relies on env inheritance across `exec`/`fork`.
- **Strip the shim dir from `PATH` before exec** — simpler, but a blunt instrument: disables *all* shims for the entire child process tree, breaking intentional nested shims.
- **Bake the Real command's absolute path into the tokens** (`.../gh` → `/usr/bin/gh`) — avoids the loop only if the wrapper accepts a path, and is brittle: hard-codes a location that breaks across machines and version managers, and does not handle self-wrap Aliases.

## Consequences

- The guard must be a **set** of names, not a boolean, so each Alias suppresses only itself.
- The dispatcher resolves the Real command by skipping the known XDG Shims directory during its `PATH` search — no `/proc/self/exe` involved on the dispatch path.
