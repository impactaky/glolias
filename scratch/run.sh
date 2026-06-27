#!/bin/sh
# Build the demo and invoke it several different ways so you can see
# exactly what argv[0] and /proc/self/exe report in each case.
set -eu
cd "$(dirname "$0")"

gcc -o argv0 argv0.c
gcc -o empty_argv empty_argv.c

# busybox/pyenv-style: one real binary, many named symlinks pointing at it
ln -sf argv0 gh
ln -sf argv0 glolias

hr() { printf '\n========== %s ==========\n' "$1"; }

hr "1) invoked through symlink ./gh"
./gh

hr "2) invoked through symlink ./glolias"
./glolias

hr "3) invoked by absolute path to the symlink"
"$(pwd)/gh"

hr "4) caller lies about argv[0] (passes a made-up name)"
python3 -c 'import os; os.execv("./gh", ["i-am-not-gh", "someArg"])'

hr "5) caller passes an EMPTY argv (argc == 0)"
./empty_argv
