# glolias — Help & CLI UX Plan

Make `glolias`'s help output friendly: a real top-level overview with
per-command descriptions, plus targeted per-command help. Lean on the existing
`zig-clap` dependency to render help rather than hand-aligning strings.

> Glossary in [`CONTEXT.md`](./CONTEXT.md); the build plan is [`plan.md`](./plan.md).
> This file covers only the help/UX surface and does not re-argue settled
> decisions. No ADR is warranted (help text is reversible, unsurprising, and
> carries no lock-in trade-off) and no new glossary term is introduced.

Scope picked: **per-command descriptions** + **per-command help**.
Explicitly out of scope: rewording error messages for actionability,
worked examples inside help, and `--version`.

---

## Single source of truth

A data-driven command table feeds **both** the top-level help and each
command's help summary line — no duplicated literals.

```zig
const CmdInfo = struct { name: []const u8, summary: []const u8 };

const commands = [_]CmdInfo{
    .{ .name = "add",    .summary = "Define an alias + create its shim" },
    .{ .name = "remove", .summary = "Delete an alias and its shim" },
    .{ .name = "sync",   .summary = "Recreate/prune shims to match config" },
    .{ .name = "list",   .summary = "List configured aliases" },
    .{ .name = "path",   .summary = "Print the shims directory" },
    .{ .name = "doctor", .summary = "Diagnose PATH and shim setup" },
};
```

The `run()` dispatch can reuse this array for name matching; the help renderer
reuses it for the table and per-command summary lines.

---

## Top-level help

Triggered by: no args, `glolias help`, `glolias -h`, `glolias --help`.
Goes to **stdout, exit 0** when explicitly requested; **stderr, non-zero** when
shown as a fallback after a parse failure (keep the existing `usage(code)`
fd-by-code convention).

Layout (clap cannot enumerate subcommands, so the `commands:` table is rendered
by a small loop over `commands`, aligning `name` → `summary`):

```text
glolias — global aliases as PATH-resident shims

usage:
  glolias <command> [args...]

commands:
  add [--force] <name> <cmd>...  Define an alias + create its shim
  remove <name>                  Delete an alias and its shim
  sync                           Recreate/prune shims to match config
  list                           List configured aliases
  path                           Print the shims directory
  doctor                         Diagnose PATH and shim setup

Run 'glolias <command> --help' for details on a command.
```

---

## Per-command help

Three equivalent triggers:

- `glolias <cmd> --help`
- `glolias <cmd> -h`
- `glolias help <cmd>`

`add` special case: only a **leading** `--help` (before `<name>`) means "help
for add". A `--help` appearing **after** `<name>` is a verbatim alias token and
must be stored, not interpreted (preserves the verbatim-token contract at
`cli.zig:107` / AC2.2).

### Mechanism — route every command through clap

All commands (including the currently hand-parsed `remove`, `sync`, `list`,
`path`, `doctor`) get their own `params` block with `-h, --help`, positionals,
and doc-comment descriptions. Help is rendered with `clap.usage` +
`clap.help` (zig-clap 0.12, `clap.zig:1397` / `2051`) into a fixed
`std.Io.Writer.fixed` buffer, then emitted via `sys.writeAll` — mirroring the
existing `failParse` pattern at `cli.zig:288`.

```zig
// per command, e.g. remove
const remove_params = clap.parseParamsComptime(
    \\-h, --help  Display help for this command and exit.
    \\<name>      Alias name to delete.
    \\
);

// no-arg commands carry just the help flag
const sync_params = clap.parseParamsComptime(
    \\-h, --help  Display help for this command and exit.
    \\
);
```

### Per-command body

Summary line (from `commands`) + usage line + `clap.help` flag/positional list
+ an optional one-line **note** where a command has a gotcha. Example, the
richest case (`add`):

```text
glolias add — Define an alias + create its shim

usage: glolias add [--force] <name> <command> [args...]

  --force   Replace an existing alias with different tokens
  <name>    Alias name (the shim to create)

Tokens after <name> are stored verbatim; leading-dash args are safe
and not parsed by glolias.
```

Notes:

- `add`'s `<command> [args...]` tail is **not** a clap positional (sliced
  manually), so its usage line carries a hand-written tail; `clap.usage` covers
  only `[--force] <name>`.
- `doctor`'s note restates the current-shell-only caveat (AC4.5).

---

## Acceptance criteria

- [ ] **ACH.1** `glolias`, `glolias help`, `glolias -h`, `glolias --help` all
      print the top-level help (tagline + aligned command table + footer) to
      **stdout**, exit **0**.
- [ ] **ACH.2** The command table is rendered from the `commands` array;
      adding a command in one place updates both the table and dispatch.
- [ ] **ACH.3** `glolias <cmd> --help`, `glolias <cmd> -h`, and
      `glolias help <cmd>` each print that command's help to stdout, exit 0,
      for every command (`add remove sync list path doctor`).
- [ ] **ACH.4** `glolias add --help` (leading) prints add's help; `glolias add
      gh curl --help` stores `["curl","--help"]` verbatim (AC2.2 still holds).
- [ ] **ACH.5** Per-command help shows summary + usage + flag/positional
      descriptions; `add` shows the verbatim-tokens note, `doctor` the
      current-shell-only note.
- [ ] **ACH.6** Help shown as a fallback after a parse error goes to **stderr**
      with a non-zero exit; explicitly requested help goes to stdout/0.

---

## Implementation watch-list (not new decisions)

- Routing the 5 hand-parsed commands through clap makes them **stricter**: clap
  rejects unknown flags / extra positionals that the old code ignored (e.g.
  `glolias list extra`). Re-run the e2e suite; AC2.x–AC4.x must still pass.
- `remove`'s old `args.len != 1` check becomes a clap positional-arity error —
  confirm the message/exit code (2) is still reasonable.
- Keep help rendering allocation-light and buffer-based to match `sys.writeAll`
  usage elsewhere.
