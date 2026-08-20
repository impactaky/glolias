# tomlc17 provenance

- Upstream: <https://github.com/cktan/tomlc17>
- Commit: `fcad7471a37b2d005edb35aaecf1c98b1c39bde2`
- Vendored files: upstream `src/tomlc17.c`, `src/tomlc17.h`, and `LICENSE`
- License: MIT; see [`LICENSE`](LICENSE)

Upstream SHA-256 checksums at the pinned commit:

- `tomlc17.c`: `d78045de6df24b48f29692827ed441a16981d59491033ef8c6747165a31bc938`
- `tomlc17.h`: `281708fa05b805c32c117fc6033b0f4248257fce3440b1ac3391853bfc8f8bb5`
- `LICENSE`: `f949d0976f85076c96fc5122f0632b5a1b806d8b2badbe968c42c97230e6e79e`

glolias compiles `tomlc17.c` directly into each module that parses config; it
does not use a system or shared tomlc17 library.

## Local differences

`tomlc17.c` uses `offsetof(page_t, data) + size` for the pool-page allocation
size instead of upstream's null-based address expression. The calculation is
equivalent, but the defined `offsetof` form does not trip Zig's undefined-
behavior instrumentation in Debug builds. The only other source change is the
required `<stddef.h>` include. The header and license are unchanged.
