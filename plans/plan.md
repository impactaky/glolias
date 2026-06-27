# glolias — Implementation Plan (MVP)

A single Zig binary that provides **global aliases** as `PATH`-resident shims.
Invoked via a symlink (`gh`, `gs`, …) it reroutes to another command via `execv`;
invoked as `glolias` it is the management CLI.

> Background and rationale live in [`CONTEXT.md`](./CONTEXT.md) (glossary) and
> [`docs/adr/`](./docs/adr/) (decisions 0001–0005). This file is the build plan;
> it does not re-argue settled decisions.

Target: **Linux, Zig 0.16**, with a small internal TOML subset parser for config parse + serialize.

> ⚠️ Code below is **illustrative pseudocode / Zig sketches**. Zig 0.16's std
> I/O API is mid-overhaul; exact signatures (`Writer`, `argsAlloc`, etc.) are
> finalized during implementation. The *logic* is the contract, not the syntax.

---

## Project layout

```
build.zig
build.zig.zon            # dependency: zig-clap
src/
  main.zig               # entry; mode detection by basename(argv[0])
  dispatch.zig           # shim path: guard, reroute, real-command resolution, exec
  config.zig             # TOML load/save, schema, defaults
  paths.zig              # XDG dirs, tilde/$HOME expansion, self-exe path
  cli.zig                # management: add / sync / list / path  (remove/doctor later)
tests/
  dispatch_test.zig
  config_test.zig
  e2e.sh                 # build, symlink, invoke, assert (covers execv paths)
```

---

## Data model

```zig
// config.zig
const Config = struct {
    version: u32,                 // currently 1
    shims_dir: []const u8,        // expanded absolute path
    aliases: StringHashMap([]const []const u8), // name -> token list
};
```

Config file (`${XDG_CONFIG_HOME:-~/.config}/glolias/config.toml`):

```toml
version = 1
shims_dir = "~/.local/share/glolias/shims"   # optional; default = XDG data

[aliases]
gh = ["op", "plugin", "run", "--", "gh"]
gs = ["git", "status"]
```

---

## Phase 1 — Dispatcher core (the tracer bullet)

Everything that happens when the binary is invoked **as a shim**.

### Mock logic

```
// main.zig
fn main():
    argv = os.argv
    name = (argv.len >= 1) ? basename(argv[0]) : ""

    if name == "" or name == "." or name == "/":
        stderr("glolias: cannot determine alias name (empty argv[0])")
        exit(127)

    if name == "glolias":
        return cli.run(argv[1..])      // management mode (Phase 2)

    return dispatch.run(name, argv[1..])   // shim mode
```

```
// dispatch.zig
fn run(name, rest_args):
    cfg = config.load()                       // parse TOML; on error -> exit 127 + stderr
    guard = parseSet(getenv("GLOLIAS_GUARD")) // colon-separated set, may be empty

    if guard.contains(name):
        // RE-ENTRANT HIT -> run the Real command, no rerouting
        real = resolveReal(name, cfg.shims_dir)   // PATH search skipping shims_dir
        if real == null:
            stderr("glolias: {name}: command not found"); exit(127)
        execTransparent(real, [name] ++ rest_args)   // argv[0] = name, NOT shim path
        // execTransparent only returns on failure:
        exit(errnoToExitCode())                       // ENOENT->127, EACCES->126

    tokens = cfg.aliases.get(name)
    if tokens == null:
        stderr("glolias: no alias '{name}' — run 'glolias sync'"); exit(127)

    // FIRST HIT -> reroute
    setenv("GLOLIAS_GUARD", guard.with(name).serialize())   // add name to set
    new_argv = tokens ++ rest_args                          // pure append (ADR transform)
    execvp(tokens[0], new_argv)        // normal PATH lookup; argv[0] = tokens[0]
    exit(errnoToExitCode())            // only reached if exec fails
```

```
// resolve the Real command, skipping our own shims dir (breaks recursion)
fn resolveReal(name, shims_dir):
    for dir in splitPath(getenv("PATH")):
        if sameDir(dir, shims_dir): continue          // never re-find the shim
        cand = join(dir, name)
        if isExecutableFile(cand): return cand
    return null

fn execTransparent(path, argv):
    execv(path, argv)            // replaces process image; transparent passthrough (ADR 0005)

fn errnoToExitCode():
    return switch errno { ENOENT => 127, EACCES => 126, else => 1 }
```

### Acceptance criteria

- [ ] **AC1.1** Invoked via symlink `gh` with config `gh = ["echo","WRAP"]`, running `gh hi`
      prints `WRAP hi` (token list prepended, original args appended).
- [ ] **AC1.2** Pure-append preserves quoting: `gh "a b"` → real command receives a
      **single** arg `a b`, not two.
- [ ] **AC1.3** **No recursion**: alias `gh = ["op-stub","gh"]` where `op-stub` re-execs
      `gh` on `PATH`. Running `gh X` terminates, and the *real* `gh` (a stub on PATH
      outside shims_dir) runs exactly once with arg `X`. `GLOLIAS_GUARD` contains `gh`
      in the re-entrant process.
- [ ] **AC1.4** Self-wrap: `gh = ["gh","--default"]` runs real `gh --default <args>`
      exactly once (guard handles direct re-entry).
- [ ] **AC1.5** Exit code is the rerouted command's own (e.g. alias to `false` → exit 1).
- [ ] **AC1.6** Reroute target missing → stderr `…command not found`, exit **127**;
      target present but non-executable → exit **126**.
- [ ] **AC1.7** Signals pass through: Ctrl-C during a long alias kills the real command
      (no orphan, shim is gone — it `execv`'d).
- [ ] **AC1.8** Symlink present but no config entry → stderr suggesting `glolias sync`,
      exit 127.
- [ ] **AC1.9** Empty `argv[0]` (see `scratch/empty_argv.c` technique) → exit 127.
- [ ] **AC1.10** Unparseable / missing config → loud stderr, exit 127.

---

## Phase 2 — `glolias add` + `glolias sync` (make it usable)

### Mock logic

```
// cli.zig
fn add(args):
    flags, pos = parseLeadingFlags(args)     // e.g. --force before the name
    name   = pos[0]
    tokens = pos[1..]                        // captured VERBATIM (shell already split)

    validateName(name)                       // reject "glolias", "/", empty, leading "-"
    if tokens.len == 0: fail("no command given")

    cfg = config.loadOrInit()
    if cfg.aliases.has(name) and cfg.aliases.get(name) != tokens and !flags.force:
        fail("alias '{name}' exists with different tokens (use --force)")
    cfg.aliases.put(name, tokens)
    config.save(cfg)                         // re-serialize whole TOML (machine-managed)
    ensureSymlink(cfg.shims_dir, name)       // shims_dir/name -> selfExePath()

fn sync():
    cfg = config.load()
    mkdirp(cfg.shims_dir)
    // create missing
    for name in cfg.aliases.keys(): ensureSymlink(cfg.shims_dir, name)
    // prune orphans (symlink in shims_dir with no matching alias)
    for link in listSymlinks(cfg.shims_dir):
        if !cfg.aliases.has(basename(link)): unlink(link)

fn ensureSymlink(shims_dir, name):
    target = selfExePath()                    // /proc/self/exe, absolute & resolved
    path   = join(shims_dir, name)
    symlinkForce(target, path)                // replace if exists/dangling
```

### Acceptance criteria

- [ ] **AC2.1** `glolias add gh op plugin run -- gh` writes
      `gh = ["op","plugin","run","--","gh"]` to config **and** creates
      `shims_dir/gh` → resolved binary path.
- [ ] **AC2.2** Tokens captured verbatim: a leading-`-` token (e.g.
      `glolias add gs git -c color.ui=always status`) is stored, not parsed as a flag.
- [ ] **AC2.3** Re-adding identical tokens → success no-op; conflicting tokens without
      `--force` → error, exit non-zero; with `--force` → overwritten.
- [ ] **AC2.4** `validateName` rejects `glolias`, names with `/`, empty, and leading `-`.
- [ ] **AC2.5** On a machine with config present but empty shims_dir, `glolias sync`
      materializes **all** symlinks pointing at the current binary (dotfiles rehydrate).
- [ ] **AC2.6** `sync` prunes a symlink whose alias was removed from config by hand.
- [ ] **AC2.7** After moving/reinstalling the binary, `sync` repoints dangling symlinks.
- [ ] **AC2.8** End-to-end: `add` an alias, ensure shims_dir is first on `PATH`,
      invoke the alias name directly → reroute works (Phase 1 ACs hold via real install).

---

## Phase 3 — `list` + `path` (visibility)

### Mock logic

```
fn list():           print aligned "ALIAS   COMMAND" header + sorted aliases
fn list(--plain):   for (name, tokens) in sorted(cfg.aliases): print("{name}\t{join(tokens,' ')}")
fn path():  print(cfg.shims_dir)     // so user can add it to PATH
```

### Acceptance criteria

- [ ] **AC3.1** `glolias list --plain` prints every alias as `name <tab> tokens`,
      sorted, no header, exit 0.
- [ ] **AC3.2** `glolias path` prints exactly the (expanded, absolute) shims_dir, nothing else.
- [ ] **AC3.3** `glolias list` prints the `ALIAS   COMMAND` header followed by
      sorted rows, with the command column aligned across the header and rows,
      exit 0.
- [ ] **AC3.4** Empty config: `glolias list` prints the header row only;
      `glolias list --plain` prints nothing. Both exit 0.

---

## Phase 4 — `remove` + `doctor` (ergonomics, after MVP proven)

### Mock logic

```
fn remove(name):
    cfg = config.load()
    if !cfg.aliases.has(name): fail("no alias '{name}'")     // error if absent
    cfg.aliases.remove(name); config.save(cfg)
    unlink(join(cfg.shims_dir, name))

fn doctor():
    // diagnoses the CURRENT shell's environment only (ADR 0004)
    report shims_dir exists and is a directory
    report whether shims_dir is on $PATH, and whether it is AHEAD of dirs
        containing a real command of the same name (shadowing check)
    report dangling symlinks / symlinks with no config entry
    report config parse status
```

### Acceptance criteria

- [ ] **AC4.1** `remove` deletes config entry + symlink; removing absent alias → error.
- [ ] **AC4.2** `doctor` flags when shims_dir is **not** on `$PATH`.
- [ ] **AC4.3** `doctor` flags when a real command shadows a shim because shims_dir is
      **after** `/usr/bin` etc. on `$PATH`.
- [ ] **AC4.4** `doctor` lists orphan symlinks and config parse errors.
- [ ] **AC4.5** `doctor` output explicitly notes it reflects only the current shell,
      not a GUI IDE's environment.

---

## Testing strategy

The shim's whole job is `execv`, so unit tests can't cover the interesting paths —
**end-to-end shell tests** are primary:

- `tests/e2e.sh`: build binary → temp `HOME`/`XDG_*` → `glolias add` stub aliases
  (rerouting to `echo`/`false`/a recursion stub on a temp `PATH`) → invoke via symlink
  → assert stdout / exit code / `GLOLIAS_GUARD`. This is the only way to prove
  AC1.3 (recursion), AC1.5–1.7 (exit/signals), AC2.8.
- Unit tests (`config_test`, `dispatch_test`) cover the pure pieces: TOML round-trip,
  `parseSet`/`serialize` for the guard, `resolveReal` against a fake PATH, name
  validation.

The `scratch/` C demo already validates the `argv[0]` / empty-argv assumptions the
dispatcher relies on; keep it as a reference or delete it.

---

## Out of scope for MVP (recorded so it isn't "forgotten")

- macOS / `_NSGetExecutablePath` (ADR 0004) — isolated behind `paths.selfExePath`.
- Auto-editing the user's `PATH`/shell config (ADR 0004 — explicit non-goal).
- Per-alias metadata (env vars, cwd, description) — `version` field reserves the
  migration path (ADR 0003).
- Comment preservation in the TOML on rewrite (ADR 0003 — machine-managed).
- Interior placeholders / positional consumption in aliases (ADR/glossary — pure append only).
```
