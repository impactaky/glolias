# Doctor is a read-only health check

`glolias doctor` is a diagnostic command with a scriptable status contract, not
only an informational report. It exits `0` when the current setup is consistent
and `1` when it finds one or more inconsistencies.

The command checks every item that remains inspectable instead of returning
after the first failure. Its checks cover:

- config existence and parsing;
- Shims directory existence and type;
- Shims directory placement on the current `PATH`;
- executables before the Shims directory that shadow configured Aliases;
- a missing, dangling, stale, or non-symlink entry for each configured Alias;
- orphan symlinks that do not correspond to configured Aliases.
- missing, malformed, non-executable, stale, mismatched, and orphan Credential
  Runners;
- dangling Credential Bindings and duplicate environment-variable providers.

A config failure prevents checks that need the Alias set, but does not prevent
independent directory, `PATH`, binary-target, or symlink inspection. A Shims
directory failure likewise does not prevent config, `PATH`, or configured-entry
checks.

Shim and stale-Runner inconsistencies include guidance to run `glolias sync`;
missing or invalid Runners require `glolias credential set`. `doctor` itself
does not create, remove, or repoint symlinks and does not modify config or
`PATH`. As established by ADR 0004, all environment checks describe only the
shell that launched `doctor`; a GUI application or IDE can have a different
environment.

## Consequences

- Scripts can use the exit status as a health gate without parsing prose.
- One invocation reports all inspectable faults, reducing repair/check cycles.
- `sync` retains its existing explicit repair behavior; `doctor` remains
  side-effect free.
- A regular file or directory blocking a configured Shim is reported, but the
  user must remove that entry before `sync` can repair it.
