# Linux-first, with opt-in environment setup deferred

Two deliberate scope boundaries for the current implementation.

**The current glolias commands do not modify the user's environment.** glolias owns a Shims directory, creates the symlinks, and reports the path (plus diagnostics on `PATH` ordering and shadowing). `add`, `sync`, and installation do **not** edit `~/.profile`, `~/.config/environment.d`, `pam_env`, launchd configuration, or similar files to put that directory on `PATH` — that remains the user's responsibility today. Environments that need shims (especially GUI-launched IDEs) obtain `PATH` from session- and OS-specific routes, so implicit edits would be intrusive and unpredictable.

An explicit, opt-in setup utility for the standard Linux and macOS environment paths is a desired future feature. It will run only when the user invokes that dedicated operation; ordinary alias management and installation will never update the environment as a side effect. The command shape and exact platform-specific files are not decided yet.

**Linux only, first.** Management commands (`add`/`sync`) self-locate the real `glolias` binary via `/proc/self/exe` to use as the symlink target; this is Linux-specific. macOS is the next intended supported platform and will require an `_NSGetExecutablePath` swap, kept isolated behind a single function so the rest of the code is platform-agnostic. Windows is out of scope for the foreseeable future because its executable, shim, command-search, and environment-setup mechanisms require a substantially different design rather than a direct port. (The dispatch path does **not** use `/proc/self/exe` — the alias name comes from `argv[0]` and the Shims directory is a known XDG path; see ADR 0002.)

## Consequences

- Environment changes must remain explicit: a future setup utility may edit standard shell/session configuration, but ordinary installation and alias-management commands must not.
- Existing shell aliases and functions remain outside glolias ownership. glolias does not detect, remove, or migrate them; users decide whether and when to replace those definitions with Global Aliases.
- `glolias doctor` diagnoses only the `PATH`/environment of the shell it runs in; it cannot inspect a GUI-launched IDE's environment. Confirming the shim is reachable from the IDE is left to the user (no probe/self-test is built).
- Cross-platform executable-path resolution is the known seam to generalize when macOS support lands.
