# Zig for the native dispatcher

glolias uses Zig because every Alias invocation passes through the dispatcher, making fast startup and a small single native binary important. Zig also provides precise control of `argv` and the environment with thin POSIX `exec` integration and no language runtime between the Shim and the Real command; the maintainer's preference for the language reinforces the choice.
