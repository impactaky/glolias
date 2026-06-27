# TOML config, machine-managed

Alias definitions live in a single TOML file (`${XDG_CONFIG_HOME:-~/.config}/glolias/config.toml`) with a top-level `version` and an `[aliases]` table mapping each name to a token-list array. We chose TOML over `std.json` (more human-friendly to read and hand-edit) and over a line-based `name = command` format (which would require a hand-rolled shell-quoting lexer + serializer — a notorious source of round-trip bugs around nested quotes, comment chars, and empty-string args). The token list is stored as a native TOML array of strings, so quoting is handled losslessly by the library on both read and write.

```toml
version = 1

[aliases]
gh = ["op", "plugin", "run", "--", "gh"]
gs = ["git", "status"]
```

The Shims directory is derived from `${XDG_DATA_HOME:-~/.local/share}/glolias/shims` rather than stored in the config. This keeps the config portable across machines: moving the shims location is an environment concern, handled by `XDG_DATA_HOME`, while the config remains only the alias mapping.

## Considered Options

- **TOML subset (chosen)** — human-friendly, native string arrays store tokens losslessly, and the project only needs `version` and an `[aliases]` table. Cost: a small internal parser/serializer rather than a full TOML implementation.
- **`std.json`** — zero dependencies and trivially correct round-trip, but config-as-JSON is unpleasant to hand-edit.
- **Line-based `name = command`** — most pleasant to hand-edit, but forces a hand-rolled shell-quoting parser *and* a mirror-image serializer that must agree forever; rejected.
- **YAML** — no maintained Zig serializer and overkill for a flat name→list map; rejected.

## Consequences

- **Internal parser:** `src/config_toml.zig` intentionally supports only the glolias config schema; it is not a vendored third-party TOML library.
- **Machine-managed contract:** `glolias add`/`remove` parse → modify → re-serialize the whole file, so **hand-added comments and custom formatting are not preserved**. The file stays readable (sorted, clean TOML) but `glolias` owns it. Comment preservation would require fragile surgical text edits and was deliberately rejected.
- **`version` field** allows future migration (e.g. value becoming an object `{tokens, env, ...}`) without ambiguity.
