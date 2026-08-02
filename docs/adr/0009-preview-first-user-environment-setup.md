# Persistent setup is preview-first, user-owned, and reversible

This decision supersedes only ADR 0004's deferral of an explicit environment setup utility. Its boundary against implicit environment changes remains: install, dispatch, and Alias management never configure `PATH`.

`glolias setup` produces a Setup Plan and does not mutate state. `--apply` is the sole authorization to apply that complete preflighted plan; `--remove` changes the plan to remove only exact glolias-owned state. There is no prompt, `sudo`, system-wide edit, current-shell mutation, session command, or cross-file rollback transaction. Conflicts stop all mutation. Each changed file is replaced atomically, and a later failure is reported as applied and pending work so an idempotent rerun can converge.

Login shells and OS-managed sessions are complementary. The managed block in `.profile` and `.zprofile` covers Bash/POSIX and Zsh login shells. Linux systemd user services use the owned `environment.d` file when that session mechanism is present; non-systemd sessions require a displayed manual step. macOS GUI/user processes use an owned LaunchAgent on a future login. Other shells remain manual.

Removal recognizes one well-formed versioned profile block and exact owned files. It preserves every profile byte outside that block and treats malformed or duplicate markers, symlinks, non-regular profile targets, unsafe path representations, and unexpected owned-file content as conflicts rather than guessing.

## Consequences

- Setup is attributable and reversible without storing transient session state.
- Applying or removing setup requires a new login/session; the invoking process and existing applications are unchanged.
- `doctor` remains a read-only diagnosis of current config, Shims, and current `PATH`; it may point to setup preview but does not inspect persistent setup files.
