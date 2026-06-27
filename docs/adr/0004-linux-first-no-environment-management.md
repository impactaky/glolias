# Linux-first, and glolias does not manage the environment

Two deliberate scope boundaries.

**glolias does not modify the user's environment.** It owns a Shims directory, creates the symlinks, and reports the path (plus diagnostics on `PATH` ordering and shadowing). It does **not** edit `~/.profile`, `~/.config/environment.d`, `pam_env`, or launchd to put that directory on `PATH` — that is the user's responsibility. We chose this over auto-configuring `PATH` (as `pyenv init` does) because the environments that need shims (GUI-launched IDEs) get `PATH` from session-/OS-specific files that are intrusive and fragile to edit, and vary per desktop/display-manager. Reporting + user-applied configuration is simpler, predictable, and avoids glolias mutating files it doesn't own.

**Linux only, first.** Management commands (`add`/`sync`) self-locate the real `glolias` binary via `/proc/self/exe` to use as the symlink target; this is Linux-specific. macOS support is a planned future port requiring an `_NSGetExecutablePath` swap, kept isolated behind a single function so the rest of the code is platform-agnostic. (The dispatch path does **not** use `/proc/self/exe` — the alias name comes from `argv[0]` and the Shims directory is a known XDG path; see ADR 0002.)

## Consequences

- A future reader expecting `glolias init` to auto-edit shell/session config should know this is an intentional non-goal.
- `glolias doctor` diagnoses only the `PATH`/environment of the shell it runs in; it cannot inspect a GUI-launched IDE's environment. Confirming the shim is reachable from the IDE is left to the user (no probe/self-test is built).
- Cross-platform executable-path resolution is the known seam to generalize when macOS support lands.
