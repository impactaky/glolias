#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$repo/zig-out/bin/glolias"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export XDG_CONFIG_HOME="$tmp/config"
export XDG_DATA_HOME="$tmp/data"
export TMPDIR_FOR_GLOLIAS_TEST="$tmp"
export PATH="$tmp/data/glolias/shims:$tmp/bin:$PATH"

mkdir -p "$tmp/bin"

zig build -Doptimize=Debug

for help_args in "" "help" "-h" "--help"; do
  set +e
  if [ -z "$help_args" ]; then
    "$bin" >"$tmp/help.out" 2>"$tmp/help.err"
  else
    # shellcheck disable=SC2086
    "$bin" $help_args >"$tmp/help.out" 2>"$tmp/help.err"
  fi
  code="$?"
  set -e
  test "$code" = "0"
  test ! -s "$tmp/help.err"
  grep -q "glolias .* global aliases as PATH-resident shims" "$tmp/help.out"
  grep -q "add \\[--force\\] <name> <cmd>\\.\\.\\.  Define an alias + create its shim" "$tmp/help.out"
  grep -q "list \\[--plain\\].*List configured aliases" "$tmp/help.out"
  grep -q "doctor                         Diagnose PATH and shim setup" "$tmp/help.out"
  grep -q "Run 'glolias <command> --help' for details on a command." "$tmp/help.out"
done

for cmd in add remove sync list path doctor; do
  "$bin" "$cmd" --help >"$tmp/help.out" 2>"$tmp/help.err"
  test ! -s "$tmp/help.err"
  grep -q "glolias $cmd .*" "$tmp/help.out"
  grep -q "usage: glolias $cmd" "$tmp/help.out"
  grep -q -- "-h, --help" "$tmp/help.out"

  "$bin" "$cmd" -h >"$tmp/help.out" 2>"$tmp/help.err"
  test ! -s "$tmp/help.err"
  grep -q "glolias $cmd .*" "$tmp/help.out"

  "$bin" help "$cmd" >"$tmp/help.out" 2>"$tmp/help.err"
  test ! -s "$tmp/help.err"
  grep -q "glolias $cmd .*" "$tmp/help.out"
done

"$bin" add --help >"$tmp/help.out" 2>"$tmp/help.err"
test ! -s "$tmp/help.err"
grep -q "Tokens after <name> are stored verbatim" "$tmp/help.out"
"$bin" help doctor >"$tmp/help.out" 2>"$tmp/help.err"
test ! -s "$tmp/help.err"
grep -q "current shell environment only" "$tmp/help.out"
"$bin" list --help >"$tmp/help.out" 2>"$tmp/help.err"
test ! -s "$tmp/help.err"
grep -q -- "--plain" "$tmp/help.out"

test "$("$bin" list)" = "ALIAS   COMMAND"
test -z "$("$bin" list --plain)"

set +e
"$bin" list extra >"$tmp/help.out" 2>"$tmp/help.err"
code="$?"
set -e
test "$code" != "0"
test ! -s "$tmp/help.out"
grep -q "Invalid argument 'extra'" "$tmp/help.err"
grep -q "glolias list .* List configured aliases" "$tmp/help.err"

"$bin" add gh echo WRAP
test "$("$bin" path)" = "$tmp/data/glolias/shims"

out="$(gh hi)"
test "$out" = "WRAP hi"

out="$(gh "a b")"
test "$out" = "WRAP a b"

"$bin" add --force gf false
"$bin" add --force g echo short
"$bin" add --force gitlog echo long
test "$("$bin" list)" = $'ALIAS   COMMAND\ng       echo short\ngf      false\ngh      echo WRAP\ngitlog  echo long'
test "$("$bin" list --plain)" = $'g\techo short\ngf\tfalse\ngh\techo WRAP\ngitlog\techo long'

set +e
out="$("$bin" add gf true 2>&1)"
code="$?"
set -e
test "$code" != "0"
[[ "$out" == *"use --force"* ]]

"$bin" add --force gs git -c color.ui=always status
grep -q '^gs = \["git", "-c", "color.ui=always", "status"\]$' "$XDG_CONFIG_HOME/glolias/config.toml"
"$bin" add --force hh curl --help
grep -q '^hh = \["curl", "--help"\]$' "$XDG_CONFIG_HOME/glolias/config.toml"

set +e
gf
code="$?"
set -e
test "$code" = "1"

"$bin" add --force missing does-not-exist
set +e
out="$(missing 2>&1)"
code="$?"
set -e
test "$code" = "127"
[[ "$out" == *"command not found"* ]]

printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/noexec"
chmod 0644 "$tmp/bin/noexec"
"$bin" add --force bad noexec
set +e
out="$(bad 2>&1)"
code="$?"
set -e
test "$code" = "126"
[[ "$out" == *"permission denied"* ]]

ln -sf "$bin" "$tmp/data/glolias/shims/unknown"
set +e
out="$(unknown 2>&1)"
code="$?"
set -e
test "$code" = "127"
[[ "$out" == *"run 'glolias sync'"* ]]

printf '#include <unistd.h>\n#include <stdio.h>\nint main(int argc, char **argv) { if (argc != 2) return 2; char *empty[] = { NULL }; execv(argv[1], empty); perror("execv"); return 1; }\n' > "$tmp/empty_argv.c"
cc -o "$tmp/empty_argv" "$tmp/empty_argv.c"
set +e
out="$("$tmp/empty_argv" "$bin" 2>&1)"
code="$?"
set -e
test "$code" = "127"
[[ "$out" == *"cannot determine alias name"* ]]

printf '#!/usr/bin/env bash\nprintf "REAL:%%s:G=%%s\\n" "$*" "${GLOLIAS_GUARD:-}"\n' > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$tmp/bin/op-stub"
chmod +x "$tmp/bin/op-stub"
"$bin" add --force gh op-stub gh
hash -r
out="$(gh X)"
test "$out" = "REAL:X:G=gh"

"$bin" add --force gh gh --default
hash -r
out="$(gh X)"
test "$out" = "REAL:--default X:G=gh"

cat > "$tmp/sig_target.c" <<'C'
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *f = fopen(argv[1], "w");
    if (!f) return 3;
    fprintf(f, "%ld\n", (long)getpid());
    fclose(f);
    sleep(10);
    return 0;
}
C
cc -o "$tmp/bin/sig-target" "$tmp/sig_target.c"
"$bin" add --force nap sig-target "$tmp/real.pid"
python3 - <<'PY'
import os
import signal
import subprocess
import sys
import time

pid_file = os.environ["TMPDIR_FOR_GLOLIAS_TEST"] + "/real.pid"
p = subprocess.Popen(["nap"])
for _ in range(50):
    if os.path.exists(pid_file):
        break
    time.sleep(0.05)
else:
    p.kill()
    sys.exit("real pid file was not written")

with open(pid_file, "r", encoding="utf-8") as f:
    real_pid = int(f.read().strip())

if real_pid != p.pid:
    p.kill()
    sys.exit(f"shim did not exec transparently: child pid {real_pid}, shim pid {p.pid}")

p.send_signal(signal.SIGINT)
rc = p.wait(timeout=2)
if rc != -signal.SIGINT:
    sys.exit(f"expected SIGINT termination, got {rc}")
PY

ln -sf "$bin" "$tmp/data/glolias/shims/orphan"
out="$("$bin" doctor)"
[[ "$out" == *"current shell environment only"* ]]
[[ "$out" == *"orphan: orphan"* ]]
out="$(PATH="$tmp/bin:/usr/bin:/bin" "$bin" doctor)"
[[ "$out" == *"path: shims_dir is not on PATH"* ]]
out="$(PATH="$tmp/bin:$tmp/data/glolias/shims:/usr/bin:/bin" "$bin" doctor)"
[[ "$out" == *"shadowing: gh is shadowed"* ]]

"$bin" sync
test ! -L "$tmp/data/glolias/shims/orphan"
rm "$tmp/data/glolias/shims/gh"
"$bin" sync
test -L "$tmp/data/glolias/shims/gh"
ln -sf /tmp/does-not-exist "$tmp/data/glolias/shims/gh"
"$bin" sync
test "$(readlink "$tmp/data/glolias/shims/gh")" = "$bin"

"$bin" remove bad
test ! -L "$tmp/data/glolias/shims/bad"
! grep -q '^bad = ' "$XDG_CONFIG_HOME/glolias/config.toml"
set +e
out="$("$bin" remove absent 2>&1)"
code="$?"
set -e
test "$code" != "0"
[[ "$out" == *"no alias 'absent'"* ]]

bad_home="$tmp/bad-config"
mkdir -p "$bad_home/glolias"
printf 'version = 1\n[aliases]\nbad/key = ["x"]\n' > "$bad_home/glolias/config.toml"
set +e
out="$(XDG_CONFIG_HOME="$bad_home" "$bin" doctor)"
code="$?"
set -e
test "$code" = "1"
[[ "$out" == *"config: error"* ]]

echo "e2e ok"
