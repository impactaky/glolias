# End-to-end tests use bats, vendored as submodules

The end-to-end suite is written for [bats-core](https://github.com/bats-core/bats-core), with `bats-support` and `bats-assert` for readable assertions. All three are vendored as **git submodules** under `tests/`, not installed from the system. The single linear `tests/e2e.sh` is replaced by per-feature `*.bats` chapter files (`dispatch.bats`, `manage.bats`, `diagnostics.bats`, `help.bats`) sharing one `tests/test_helper/common.bash`.

The driving goal is **readability**: each `@test` is a self-contained use case that reads like a worked example from the README. The shim's whole job is `execv` (ADR 0005), so e2e is the only place the interesting paths can be proven — which makes that suite, not the unit tests, the primary description of behavior. A 250-line accumulating bash script hid those use cases; per-test isolation + `assert_*` helpers surface them.

```bash
@test "gh wraps a command transparently" {
    glolias add gh echo WRAP
    run gh hi
    assert_success
    assert_output "WRAP hi"
}
```

Run with `zig build e2e`, which builds the binary, passes its path to the suite via `GLOLIAS_BIN`, and runs bats as a child process. `zig build test` stays unit-only and submodule-free, so the fast feedback loop is unaffected.

## Considered Options

- **bats + vendored submodules (chosen)** — `@test` titles are the use-case names; `bats-assert` (`assert_success`, `assert_output --partial`) reads like prose, replacing the raw `grep -q` / `[[ == * ]]` / `set +e` dance. Vendoring pins versions and keeps the suite runnable with one `git submodule update --init`, with no per-contributor install step.
- **Homegrown bash mini-DSL** — zero new dependencies and matches the project's dependency-light stance, but every `scenario`/`expect_*` helper and its output formatting must be hand-built and maintained. Rejected in favour of a standard framework whose assertion library already reads narratively.
- **bats via system install** — keeps the repo clean, but adds a manual prerequisite to the README and lets assertion behavior drift with the installed bats version. Rejected for reproducibility.
- **Port e2e to Zig** — unit tests can't drive the `execv`/signal/`PATH` paths the shim exists for; a shell harness invoking the real binary through real symlinks is the natural fit. Rejected.

## Consequences

- **New dev dependency on `git` + bash for e2e.** Cloning needs `--recurse-submodules` (or a follow-up `git submodule update --init`). `zig build test` (unit) does **not** need the submodules; only `zig build e2e` does.
- **`.gitmodules` gains three entries.** This is the project's first external dependency not fetched by Zig itself — a deliberate, scoped exception for test tooling.
- **No mechanical AC traceability.** Test titles are pure use-case prose with no `ACx.y` tags, so coverage of the criteria in `plans/*.md` is a human judgment, verified at port time rather than enforced by naming.
- **Fixtures live in `tests/fixtures/`.** The inline C programs (`empty_argv.c`, `sig_target.c`), stub scripts, and the bad-config TOML move to named files, compiled/prepared once in `setup_file()`. The Python signal-passthrough driver is rewritten in bash, removing the Python dependency.
