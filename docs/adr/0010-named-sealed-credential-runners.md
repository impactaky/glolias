---
status: accepted
---

# Named sealed Credentials use personalized executable runners

For headless SSH users, glolias stores each named Credential in a copy of the
current executable with a versioned, end-discoverable, OS-neutral trailer. The
trailer authenticates the Credential identity and environment metadata and
contains an AEAD-protected secret plus masked recovery material; because all
recovery material shares the artifact, this is deliberately obfuscation and a
review boundary, not cryptographic protection from deliberate analysis,
debugging, modification, or process-memory inspection by the same Unix user.

## Considered Options

- Desktop keychains, Secret Service, GPG, and provider commands were rejected
  because the target is a non-interactive, headless SSH environment and these
  add session services, prompts, or a plaintext stdout integration surface.
- Root services, systemd credentials, and a daemon were rejected because the
  feature is user-owned, portable to macOS, and must add no privileged or
  long-running component.
- Compiling a secret into a new program at runtime was rejected because glolias
  ships one native executable and must not require a Zig compiler on the target.
- Same-user cryptographic secrecy was rejected as an impossible promise when
  the same user can read, copy, debug, or modify the executable that recovers
  the value. External read-only sandbox policy is part of the intended boundary.

## Consequences

Credential configuration contains only public metadata and ordered Bindings.
Creation and rotation require one hidden `/dev/tty` entry; there is no supported
get or export path. A bound Alias preflights the complete Chain, then each Runner
overwrites its environment assignment and `exec`s the next Runner or dispatcher.
The final dispatch still replaces the process with `execv`/`execvp`, preserving
ADR 0005 without a `fork`+`wait` wrapper. Structurally valid Runners can be moved
onto a new executable base by `sync` without revealing their secret.

The trailer modifies executable bytes without parsing ELF or Mach-O. Current
release artifacts are unsigned; signed or notarized macOS artifacts would make
that mutation invalid and require a different Runner format.
