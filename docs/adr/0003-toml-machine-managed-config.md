# TOML config, machine-managed

Alias and public Credential definitions live in one TOML file
(`${XDG_CONFIG_HOME:-~/.config}/glolias/config.toml`) with a top-level version.
Version 2 stores each Alias's token list and ordered Credential names plus each
Credential's environment-variable name. Secret values and all Runner-private
material remain outside config. Version 1 remains readable as Aliases with no
Credential Bindings and is upgraded only by a later successful mutation.

```toml
version = 2

[credentials]
op = "OP_SERVICE_ACCOUNT_TOKEN"

[aliases]
gh.tokens = ["op", "plugin", "run", "--", "gh"]
gh.credentials = ["op"]
gs.tokens = ["git", "status"]
gs.credentials = []
```

The Shims directory is derived from `${XDG_DATA_HOME:-~/.local/share}/glolias/shims` rather than stored in the config. This keeps the config portable across machines: moving the shims location is an environment concern, handled by `XDG_DATA_HOME`, while the config remains only the alias mapping.

## Considered Options

- **Vendored TOML parser plus project-owned schema adapter and serializer
  (chosen)** — `tomlc17` provides standards-compliant TOML parsing while the
  Zig adapter accepts only the fixed glolias root, `[credentials]`, and
  `[aliases]` schema. The existing serializer keeps deterministic version-2
  output. The parser's C source is pinned and compiled into glolias, avoiding a
  runtime shared-library or system-package dependency.
- **Internal TOML subset parser** — avoids vendored code, but duplicates TOML
  string, key, array, comment, and table syntax and rejects standard spellings
  that decode to the same schema.
- **`std.json`** — zero dependencies and trivially correct round-trip, but config-as-JSON is unpleasant to hand-edit.
- **Line-based `name = command`** — most pleasant to hand-edit, but forces a hand-rolled shell-quoting parser *and* a mirror-image serializer that must agree forever; rejected.
- **YAML** — no maintained Zig serializer and overkill for a flat name→list map; rejected.

## Consequences

- **Parser/schema ownership:** vendored `tomlc17` owns TOML syntax and returns a
  decoded tree. `src/config_toml.zig` copies that tree into Zig-owned glolias
  values while rejecting unknown fields, wrong types, incomplete Aliases, and
  invalid names or Bindings. The adapter does not re-scan raw TOML to impose a
  second syntax subset.
- **Project-owned serialization:** glolias continues to emit deterministic
  version-2 TOML using canonical bare keys, basic strings, and arrays; no
  generic encoder or third-party AST is part of the write path.
- **Machine-managed contract:** Alias and Credential mutations parse → modify →
  re-serialize the whole file, so **hand-added comments and custom formatting are
  not preserved**. The file stays readable (sorted, clean TOML) but `glolias`
  owns it. Comment preservation would require fragile surgical text edits and
  was deliberately rejected.
- **`version` field** made the version-1 to version-2 Alias representation
  migration unambiguous and remains available for future schema evolution.
- **Alias keys have one shared decoded CLI/config contract:** names match
  `[A-Za-z0-9_][A-Za-z0-9_-]*`, with `glolias` reserved. Standard TOML syntax
  such as a quoted key is accepted when its decoded name satisfies that same
  contract; decoded `.`, Unicode, whitespace, or `:` names remain invalid.
- **No project-local overlays:** Alias resolution uses the single per-user config and never changes with the current working directory. Project-specific environment or command selection belongs to separate tools rather than glolias.
