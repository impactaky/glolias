# Shim is transparent: execv, never fork+wait

The Shim replaces its own process image via `execv`/`execvp` and disappears; it never `fork`s and `wait`s for the rerouted command. As a result the Shim is fully transparent — the rerouted command inherits the same process, so its exit code, signal handling (Ctrl-C, SIGTERM, job control), and stdin/stdout/stderr/tty/cwd/env all pass through with zero forwarding logic. The accepted trade-off is that the Shim can never run code *after* the command (no output post-processing, cleanup, or wrapping), which is exactly correct for a transparent alias.

## Exit codes

When the Shim cannot exec and must report for itself, it follows shell conventions so it is indistinguishable from a real command to scripts:

- `execvp` → `ENOENT` (reroute target not on `PATH`) ⇒ exit **127** ("command not found")
- `execvp` → `EACCES` (found but not executable) ⇒ exit **126**
- glolias-internal faults (config unparseable, symlink with no config entry) ⇒ also exit **127**, but with an attributing message on **stderr** (e.g. `glolias: no alias 'gh' — run 'glolias sync'`). Stderr attributes the fault to glolias for the human; the exit code stays conventional for the machine.

## Considered Options

- **execv, no fork (chosen)** — total transparency for free; cannot act after the command.
- **posix_spawn / fork + wait** — would allow post-command behavior, but requires manual signal forwarding and exit-code relaying, and breaks the "indistinguishable from the real command" goal. Rejected; no use case needs post-processing.
