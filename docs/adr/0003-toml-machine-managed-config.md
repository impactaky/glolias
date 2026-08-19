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

- **TOML subset (chosen)** — human-friendly, native string arrays store tokens
  and ordered Bindings losslessly, and the schema needs only its fixed root,
  `[credentials]`, and `[aliases]` tables. Cost: a small internal
  parser/serializer rather than a full TOML implementation.
- **`std.json`** — zero dependencies and trivially correct round-trip, but config-as-JSON is unpleasant to hand-edit.
- **Line-based `name = command`** — most pleasant to hand-edit, but forces a hand-rolled shell-quoting parser *and* a mirror-image serializer that must agree forever; rejected.
- **YAML** — no maintained Zig serializer and overkill for a flat name→list map; rejected.

## Consequences

- **Internal parser:** `src/config_toml.zig` intentionally supports only the glolias config schema; it is not a vendored third-party TOML library.
- **Machine-managed contract:** Alias and Credential mutations parse → modify →
  re-serialize the whole file, so **hand-added comments and custom formatting are
  not preserved**. The file stays readable (sorted, clean TOML) but `glolias`
  owns it. Comment preservation would require fragile surgical text edits and
  was deliberately rejected.
- **`version` field** made the version-1 to version-2 Alias representation
  migration unambiguous and remains available for future schema evolution.
- **Alias keys have one shared CLI/config contract:** names match `[A-Za-z0-9_][A-Za-z0-9_-]*`, with `glolias` reserved. The parser and serializer apply that same rule, so CLI-accepted names cannot fail only when saved. Supporting `.`, Unicode, whitespace, `:`, or quoted TOML keys is deliberately outside the schema.
- **No project-local overlays:** Alias resolution uses the single per-user config and never changes with the current working directory. Project-specific environment or command selection belongs to separate tools rather than glolias.
