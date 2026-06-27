# glolias — e2e Test Readability Plan

Replace the single 250-line `tests/e2e.sh` — one flowing script with
accumulating shared state, raw `grep -q` / `test` assertions, repeated
`set +e`/`set -e` dances, and inline C/Python fixtures — with a **bats** suite
where every `@test` is a self-contained use case that reads like a worked
example from the README.

> Glossary in [`CONTEXT.md`](../CONTEXT.md); decisions in
> [`docs/adr/`](../docs/adr/) (this plan is recorded as
> [ADR 0006](../docs/adr/0006-bats-e2e-suite.md)); the build plan is
> [`plan.md`](./plan.md). This file covers only the e2e suite rewrite. It
> introduces no new glossary term — the test titles speak the existing terms
> (Shim, Alias, Real command, Shims directory).

Goal picked: **narrative use-case tests** (not literate/executable-README).
Out of scope: deriving tests from README prose (doctest), generating docs from
tests, and mechanical AC-id tagging.

---

## Tooling

[bats-core] + [bats-support] + [bats-assert], all vendored as **git
submodules** under `tests/`. The assert library is what makes a test read like
prose:

```bash
@test "gh wraps a command transparently" {
    glolias add gh echo WRAP
    run gh hi
    assert_success
    assert_output "WRAP hi"
}
```

`assert_output --partial` / `assert_line --partial` replace the many
`[[ "$out" == *"..."* ]]` and `grep -q` checks (help text, error messages).

[bats-core]: https://github.com/bats-core/bats-core
[bats-support]: https://github.com/bats-core/bats-support
[bats-assert]: https://github.com/bats-core/bats-assert

---

## Isolation — fresh state per test

`setup()` gives each `@test` a clean `XDG_CONFIG_HOME`/`XDG_DATA_HOME` and a
clean `PATH` (shims dir + stub bin ahead of the system). Each test adds only the
aliases its own story needs — no order dependency, no pile-up. The binary is
built **once** in `setup_file()` (really: built by `zig build e2e` and passed in
via `$GLOLIAS_BIN`; see below).

Inherently-sequential stories live as ordered steps **within one** `@test`,
because they are one use case — e.g. sync: rehydrate → prune orphan → repoint
dangling.

---

## File layout

Chapter files (filename = chapter title) sharing one helper:

```
tests/
  bats/                     # submodule: bats-core
  test_helper/
    bats-support/           # submodule
    bats-assert/            # submodule
    common.bash             # setup()/setup_file(), make_stub, shims_dir helper
  fixtures/
    empty_argv.c            # AC1.9 — empty argv[0]
    sig_target.c            # AC1.7 — writes pid, sleeps (signal target)
    real_gh.sh              # AC1.3/1.4 — fake *real* gh, echoes args + GLOLIAS_GUARD
    op_stub.sh              # AC1.3 — re-exec'ing wrapper (exec "$@")
    bad_config.toml         # AC1.10/AC4.4 — unparseable config
  dispatch.bats             # Shim dispatch     — AC1.1–1.10
  manage.bats               # Managing aliases  — AC2.x, AC3.x, ACL.x
  diagnostics.bats          # Doctor & sync     — AC4.x, AC2.5–2.7
  help.bats                 # CLI help          — ACH.x
```

`tests/e2e.sh` is **deleted** once parity is confirmed.

---

## Per-chapter contents

### `dispatch.bats` — Shim dispatch (AC1.x)

- wraps a command transparently (AC1.1)
- quoting preserved, pure append: `gh "a b"` → single arg (AC1.2)
- no recursion: `op_stub.sh` re-execs `gh`; real `gh` runs once, `GLOLIAS_GUARD`
  contains `gh` (AC1.3)
- self-wrap: `gh = ["gh","--default"]` runs real gh once (AC1.4)
- exit code is the rerouted command's own (alias → `false` → 1) (AC1.5)
- target missing → stderr + exit 127; non-executable → exit 126 (AC1.6)
- **signals pass through** (AC1.7) — see below
- symlink present, no config entry → suggests `glolias sync`, exit 127 (AC1.8)
- empty `argv[0]` via `fixtures/empty_argv` → exit 127 (AC1.9)
- unparseable config → loud stderr, exit 127 (AC1.10)

### `manage.bats` — Managing aliases (AC2.x, AC3.x, ACL.x)

- `add` writes config entry + creates shim symlink (AC2.1)
- tokens captured verbatim (leading-dash safe) (AC2.2)
- re-add identical = no-op; conflict → error; `--force` overwrites (AC2.3)
- `validateName` rejects `glolias`, `/`, empty, leading `-` (AC2.4)
- `list` pretty (`ALIAS   COMMAND`, aligned) (ACL.1, ACL.2 / AC3.3)
- `list --plain` (tab-separated, no header) (ACL.3 / AC3.1)
- `list` empty → header only; `--plain` empty → nothing (ACL.4 / AC3.4)
- `list extra` → usage on stderr, non-zero (clap strictness)
- `path` prints exactly the shims dir (AC3.2)
- `remove` deletes entry + symlink; removing absent → error (AC4.1)

### `diagnostics.bats` — Doctor & sync (AC4.x, AC2.5–2.7)

- `doctor` notes current-shell-only caveat (AC4.5)
- `doctor` flags shims_dir not on `$PATH` (AC4.2)
- `doctor` flags shadowing when shims_dir is after `/usr/bin` (AC4.3)
- `doctor` lists orphan symlinks and config parse errors (AC4.4)
- `sync` rehydrates all symlinks into empty shims dir (AC2.5)
- `sync` prunes orphan symlink with no config entry (AC2.6)
- `sync` repoints dangling/wrong symlink at the current binary (AC2.7)

### `help.bats` — CLI help (ACH.x), grouped + internal loops

- every entry point (`""`, `help`, `-h`, `--help`) shows top-level help on
  stdout, exit 0 (ACH.1)
- every command exposes `--help` / `-h` / `help <cmd>` (loop over
  `add remove sync list path doctor`) (ACH.3)
- `add --help` notes verbatim tokens; `add gh curl --help` stores
  `["curl","--help"]` (ACH.4)
- `doctor` help notes current-shell-only; `list` help shows `--plain` (ACH.5)
- help shown as parse-error fallback → stderr, non-zero (ACH.6)

---

## Signal-passthrough test (AC1.7) — bash, no Python

The old Python driver is rewritten in bash, keeping **both** assertions:

1. **Transparency** — the pid the real process writes to its pid-file equals the
   pid bats launched ⇒ the shim `execv`'d (no fork).
2. **Signal kills it** — `kill -INT` then `wait` returns 130 (128 + SIGINT).

```bash
@test "Ctrl-C passes through to the real command" {
    glolias add nap "$FIXTURES/sig-target" "$BATS_TEST_TMPDIR/real.pid"
    nap & launched=$!
    # poll until the real process records its pid
    for _ in $(seq 50); do [ -s "$BATS_TEST_TMPDIR/real.pid" ] && break; sleep 0.05; done
    [ "$(cat "$BATS_TEST_TMPDIR/real.pid")" -eq "$launched" ]   # transparency
    kill -INT "$launched"
    run wait "$launched"
    [ "$status" -eq 130 ]                                       # SIGINT termination
}
```

---

## Build & run integration

New `e2e` step in `build.zig` runs bats as a child of the build; `zig build
test` stays unit-only (no submodules needed for the fast loop):

```zig
const e2e = b.addSystemCommand(&.{ "tests/bats/bin/bats", "tests" });
e2e.setEnvironmentVariable("GLOLIAS_BIN", b.getInstallPath(.bin, "glolias"));
e2e.step.dependOn(b.getInstallStep());
const e2e_step = b.step("e2e", "Run bats end-to-end tests");
e2e_step.dependOn(&e2e.step);
```

`setup_file()` reads `$GLOLIAS_BIN` instead of calling `zig build`.

README "Run tests" section becomes:

```sh
zig build test                 # unit tests
git submodule update --init    # first time only
zig build e2e                  # end-to-end (bats)
```

---

## Implementation order (each independently verifiable)

1. Add the three submodules + `build.zig` `e2e` step + a one-test smoke
   `dispatch.bats`; confirm `zig build e2e` is green.
2. Port `dispatch.bats` fully (fixtures extracted, signal test in bash).
3. Port `manage.bats`, then `diagnostics.bats`, then `help.bats`.
4. Delete `tests/e2e.sh`, update README, run a coverage-parity pass against
   `plan.md` / `plan-help.md` / `plan-list.md`.

---

## Acceptance criteria

- [ ] **ACE.1** `zig build e2e` builds the binary and runs the bats suite to
      green; `zig build test` still runs unit tests only and needs no submodules.
- [ ] **ACE.2** Each chapter file's `@test`s pass with **fresh per-test state**
      (no cross-test ordering dependency).
- [ ] **ACE.3** Every behavior asserted by the old `tests/e2e.sh` is covered by
      a `@test` (coverage-parity pass; nothing silently dropped). AC1.1–AC4.5,
      ACH.x, ACL.x.
- [ ] **ACE.4** Fixtures live in `tests/fixtures/`; no inline C heredocs and no
      Python in the suite.
- [ ] **ACE.5** `tests/e2e.sh` is deleted and the README "Run tests" section
      documents `zig build e2e` + `git submodule update --init`.

---

## Implementation watch-list (not new decisions)

- bats `run` captures `$status`/`$output` but does **not** background processes;
  the signal test must use raw bash (`&`, `wait`) inside the `@test`, not `run`.
- Pin each submodule to a release tag, not a moving branch.
- `assert_output` matches the whole output; use `--partial` for the help/error
  substring checks that were `grep -q` before.
- Compiling the C fixtures needs a `cc` on the dev/CI machine (already assumed by
  the old suite); guard with a clear skip message if absent.
- No mechanical AC traceability (titles are pure prose) — ACE.3 parity is a
  human-verified gate, not enforced by naming.
