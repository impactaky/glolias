# glolias — Context Glossary

The shared language of this project. Glossary only — no implementation details, no specs.

## Terms

### Global Alias
An Alias available consistently across one user's execution contexts, including shells, scripts, IDEs, and GUI-launched tools. “Global” means cross-context for that user, not system-wide across every user on a machine.

### Shim
A real, `PATH`-resident executable that **shadows** a command name (e.g. `gh`) by sitting on `PATH` ahead of the real command, intercepts every invocation of that name, and reroutes it to a different command line. Unlike a shell `alias`, a Shim works in *any* `execv` context — scripts, IDEs, other programs — because it is an actual executable, not a shell-interactive construct. It intercepts only name-based `PATH` resolution; an explicit absolute or relative executable path bypasses the Shim.

> Motivating case: an app such as Codex calls `gh` directly via `execvp`, so zsh never parses that invocation and `alias gh='op plugin run -- gh'` does not apply. Shell aliases are not inherited by child processes, so this remains true even when the app itself was launched from zsh. A Shim named `gh` on `PATH` does apply.

### Alias
A named mapping from a command name to a **token list** (the replacement `argv` head). When the Shim for that name runs, it builds the new argument vector as `tokens ++ original_args` and execs it. Pure append: original args are passed through unchanged, never re-split, never spliced into the interior of the token list. This mirrors shell `alias` semantics (prefix substitution) but without re-word-splitting.

- `gh` → `["op","plugin","run","--","gh"]` ⇒ `gh foo` runs `op plugin run -- gh foo`
- `gs` → `["git","status"]` ⇒ `gs foo` runs `git status foo`

Explicitly out of scope: interior placeholders (`$1`, `$@` in the middle) and positional consumption. An Alias only ever prepends.

### Credential
A named secret environment assignment: one portable environment-variable name and one current value. Its name is the stable identity used by Aliases; its value is never part of Alias configuration.

### Credential Binding
An ordered, Alias-owned association with a Credential. Bindings are many-to-many: an Alias may consume several Credentials, and a Credential may serve several Aliases.

### Credential Runner
A personalized executable artifact that carries exactly one Credential and can apply it only as part of an authorized Credential Chain. It is an obfuscation and review boundary, not protection from deliberate extraction by the same Unix user.

### Credential Chain
The ordered, exec-only passage through an Alias's bound Credential Runners before its normal dispatch. A Chain preserves the process boundary while applying each declared Credential exactly once.

### Shims directory
The single directory that `glolias` owns and populates with the symlinks (one per Alias) pointing at the dispatcher binary. Its location follows the XDG data path (`${XDG_DATA_HOME:-~/.local/share}/glolias/shims`) so the config stays portable across machines. For Shims to take effect, the user places this directory on `PATH` ahead of the Real commands it shadows. Ordinary installation and Alias management never change the environment; persistent user setup is a separate, explicit operation.

### Real command
The genuine executable that a Shim ultimately reroutes to (e.g. the actual `/usr/bin/gh`). Distinct from the Shim that shadows its name. Resolving the Real command without re-invoking the Shim (infinite recursion) is a core concern — see ADRs.

### Setup Plan
An inspectable description of additions, removals, conflicts, no-ops, and manual steps for user-owned persistent environment setup. A Setup Plan is separate from applying it: previewing is read-only, and explicit authorization is required before its changes occur.

### Doctor
A read-only diagnosis of config, the Shims directory, and the current shell's `PATH`. A Doctor reports every inspectable inconsistency without repairing state.
