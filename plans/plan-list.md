# glolias — `list` Readability Plan

Make `glolias list` easy to scan. Today it prints `name<tab><space-joined
tokens>`, one row per alias; the single tab snaps to 8-column stops, so aliases
of different name-lengths stagger and the token column never lines up, and there
are no labels.

> Glossary in [`CONTEXT.md`](./CONTEXT.md); the build plan is [`plan.md`](./plan.md);
> the help/UX surface is [`plan-help.md`](./plan-help.md). This file covers only
> `glolias list`. No ADR is warranted (output formatting and a `--plain` flag
> are reversible, unsurprising, and carry no lock-in) and no new glossary term is
> introduced (`ALIAS` already exists; `COMMAND` is general CLI vocabulary).

Scope picked: **column alignment** + **header/labels**.
Out of scope: disambiguating tokens that themselves contain spaces, and
copy-paste-as-`glolias add` output.

---

## Two modes

`list` becomes both a human view and (under a flag) the script-stable interface.
It is routed through `clap` like every other command (see `plan-help.md`), with
its own params block:

```zig
const list_params = clap.parseParamsComptime(
    \\-h, --help   Display help for this command and exit.
    \\--plain      Tab-separated, header-less output for scripts.
    \\
);
```

### Default — pretty (human-facing) → stdout

- Header row `ALIAS   COMMAND`, **uppercase** (ls -l / ps / kubectl convention).
  `ALIAS` matches the glossary term exactly; `COMMAND` is the friendly read of
  the token line.
- `ALIAS` column **left-aligned**, padded to
  `max(len("ALIAS"), longest alias name) + 2` spaces, so the header and every
  row share one column edge.
- Rows sorted by name (existing `config.sortedAliasKeys`); tokens space-joined.
- **Empty state:** print the header row only — proves the command ran — no rows.

```text
ALIAS   COMMAND
gh      op plugin run -- gh
gs      git status
```

### `--plain` — machine-facing → stdout

- Exactly the current format: `name<tab><space-joined tokens>\n`, no header.
  **Preserves AC3.1 verbatim** under this flag.
- **Empty state:** nothing (zero rows, clean for pipelines).

```text
gh<TAB>op plugin run -- gh
gs<TAB>git status
```

---

## Acceptance criteria

- [ ] **ACL.1** `glolias list` (no flag) prints the `ALIAS   COMMAND` header
      followed by sorted rows; the token column is aligned across all rows and
      the header. Exit 0.
- [ ] **ACL.2** Alignment holds when names differ in length (e.g. `g` and
      `gitlog`): all `COMMAND` cells start at the same column.
- [ ] **ACL.3** `glolias list --plain` emits `name<tab>tokens`, sorted, no
      header — byte-for-byte the pre-change format (supersedes/relocates AC3.1).
- [ ] **ACL.4** Empty config: `glolias list` prints the header row only;
      `glolias list --plain` prints nothing. Both exit 0.
- [ ] **ACL.5** `glolias list --help` / `-h` prints list's help (per
      `plan-help.md`), including the `--plain` flag.

---

## Knock-on change to `plan.md`

`AC3.1` ("`glolias list` prints every alias as `name <tab> tokens`, sorted, exit
0") no longer describes the **default** output — it now describes `--plain`.
Update `plan.md` AC3.1 to point at `--plain`, and add the pretty-default +
header + header-only-empty-state criteria (ACL.1–ACL.4 above).

---

## Implementation watch-list (not new decisions)

- Column width uses byte/codepoint length of alias names. Fine in practice —
  `validateName` only blocks `/`, leading `-`, empty, and `glolias`, so names
  are effectively ASCII; an exotic multibyte name could misalign by a hair, not
  handled in MVP.
- Keep rendering buffer-based via `sys.writeAll` to match the rest of the CLI.
- `--plain` must remain a pure prefix flag handled by clap before any rows are
  emitted; it changes format only, never which aliases are shown.
