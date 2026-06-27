# glolias — Context Glossary

The shared language of this project. Glossary only — no implementation details, no specs.

## Terms

### Shim
A real, `PATH`-resident executable that **shadows** a command name (e.g. `gh`) by sitting on `PATH` ahead of the real command, intercepts every invocation of that name, and reroutes it to a different command line. Unlike a shell `alias`, a Shim works in *any* `execv` context — scripts, IDEs, other programs — because it is an actual executable, not a shell-interactive construct.

> Motivating case: an IDE calls `gh` directly via `execvp` and never sources the user's zshrc, so a shell `alias gh='op plugin run -- gh'` does not apply. A Shim named `gh` on `PATH` does.

### Alias
A named mapping from a command name to a **token list** (the replacement `argv` head). When the Shim for that name runs, it builds the new argument vector as `tokens ++ original_args` and execs it. Pure append: original args are passed through unchanged, never re-split, never spliced into the interior of the token list. This mirrors shell `alias` semantics (prefix substitution) but without re-word-splitting.

- `gh` → `["op","plugin","run","--","gh"]` ⇒ `gh foo` runs `op plugin run -- gh foo`
- `gs` → `["git","status"]` ⇒ `gs foo` runs `git status foo`

Explicitly out of scope: interior placeholders (`$1`, `$@` in the middle) and positional consumption. An Alias only ever prepends.

### Shims directory
The single directory that `glolias` owns and populates with the symlinks (one per Alias) pointing at the dispatcher binary. Its location follows the XDG data path (`${XDG_DATA_HOME:-~/.local/share}/glolias/shims`) so the config stays portable across machines. For Shims to take effect, the user must place this directory on `PATH` ahead of the real commands it shadows. `glolias` reports this directory and can diagnose `PATH` ordering, but does **not** modify the user's environment itself — putting it on `PATH` is the user's responsibility.

### Real command
The genuine executable that a Shim ultimately reroutes to (e.g. the actual `/usr/bin/gh`). Distinct from the Shim that shadows its name. Resolving the Real command without re-invoking the Shim (infinite recursion) is a core concern — see ADRs.
