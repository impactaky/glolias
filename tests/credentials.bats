#!/usr/bin/env bats

load test_helper/common

first_secret='SYNTHETIC_GLOLIAS_FIRST_7H3Q9K'
second_secret='SYNTHETIC_GLOLIAS_SECOND_4P8M2R'

@test "credential set reads a synthetic secret only from a hidden TTY and stores metadata separately" {
  require_pty_fixture

  run --separate-stderr credential_set first op OP_TEST_TOKEN
  assert_success
  refute_output --partial "$first_secret"
  refute_stderr --partial "$first_secret"

  assert_config_line 'op = "OP_TEST_TOKEN"'
  refute_config_line "$first_secret"
  runner="$(credentials_dir)/op"
  assert [ -x "$runner" ]
  mode="$(stat -c '%a' "$runner" 2>/dev/null || stat -f '%Lp' "$runner")"
  assert_equal "$mode" 500
  run grep -a -F "$first_secret" "$runner"
  assert_failure
  run strings "$runner"
  assert_success
  refute_output --partial "$first_secret"
}

@test "credential set refuses non-TTY use without creating config or a partial runner" {
  run --separate-stderr glolias credential set op OP_TEST_TOKEN

  assert_failure
  refute_output
  assert_stderr --partial "/dev/tty is unavailable"
  assert [ ! -e "$(config_file)" ]
  assert [ ! -e "$(credentials_dir)/op" ]
  run find "$(credentials_dir)" -type f
  assert_success
  refute_output
}

@test "credential set restores TTY echo after successful and rejected entry" {
  require_pty_fixture
  check='"$1" credential set "$2" "$3"; result=$?; stty -a | grep -Eq "(^|[[:space:];])echo([[:space:];]|$)" && echo ECHO_RESTORED; exit "$result"'

  run "$COMPILED_FIXTURES/pty-secret" first /bin/sh -c "$check" sh "$GLOLIAS_BIN" success SUCCESS_TOKEN
  assert_success
  assert_output --partial "ECHO_RESTORED"
  refute_output --partial "$first_secret"

  run "$COMPILED_FIXTURES/pty-secret" empty /bin/sh -c "$check" sh "$GLOLIAS_BIN" empty EMPTY_TOKEN
  assert_failure
  assert_output --partial "ECHO_RESTORED"
  assert_output --partial "empty secrets are refused"
}

@test "one Credential serves multiple Aliases and one Alias receives multiple Credentials" {
  require_pty_fixture
  credential_set first one FIRST_TOKEN
  credential_set second two SECOND_TOKEN
  glolias add first-alias /usr/bin/env
  glolias add second-alias /usr/bin/env
  glolias credential attach one first-alias second-alias
  glolias credential attach two second-alias

  run env FIRST_TOKEN=STALE second-alias
  assert_success
  assert_output --partial "FIRST_TOKEN=$first_secret"
  assert_output --partial "SECOND_TOKEN=$second_secret"

  run first-alias
  assert_success
  assert_output --partial "FIRST_TOKEN=$first_secret"
  refute_output --partial "SECOND_TOKEN=$second_secret"
}

@test "rotation preserves bindings and the next invocation receives only the new value" {
  require_pty_fixture
  credential_set first op ROTATING_TOKEN
  glolias add --credential op rotated /usr/bin/env

  run rotated
  assert_success
  assert_output --partial "ROTATING_TOKEN=$first_secret"

  run --separate-stderr credential_set second op ROTATING_TOKEN
  assert_success
  refute_output --partial "$second_secret"
  assert_config_line 'rotated.credentials = ["op"]'

  run rotated
  assert_success
  assert_output --partial "ROTATING_TOKEN=$second_secret"
  refute_output --partial "ROTATING_TOKEN=$first_secret"
}

@test "duplicate Credential environment names fail before the target starts" {
  require_pty_fixture
  credential_set first one DUPLICATE_TOKEN
  credential_set second two DUPLICATE_TOKEN
  make_stub must-not-run "touch '$BATS_TEST_TMPDIR/target-ran'"
  glolias add --credential one --credential two blocked must-not-run

  run -127 --separate-stderr blocked
  assert_failure 127
  assert_stderr --partial "DuplicateCredentialEnvironment"
  assert [ ! -e "$BATS_TEST_TMPDIR/target-ran" ]
}

@test "tampered and missing runners fail closed instead of using an ambient value" {
  require_pty_fixture
  credential_set first op SEALED_TOKEN
  make_stub target "printf '%s' \"\${SEALED_TOKEN-unset}\" >'$BATS_TEST_TMPDIR/observed'"
  glolias add --credential op sealed target
  runner="$(credentials_dir)/op"
  size="$(wc -c <"$runner")"
  chmod 0700 "$runner"
  printf '\001' | dd of="$runner" bs=1 seek="$((size - 21))" conv=notrunc status=none
  chmod 0500 "$runner"

  run -127 --separate-stderr env SEALED_TOKEN=AMBIENT sealed
  assert_failure 127
  assert_stderr --partial "RunnerAuthenticationFailed"
  assert [ ! -e "$BATS_TEST_TMPDIR/observed" ]

  credential_set second op SEALED_TOKEN
  rm "$runner"
  run -127 --separate-stderr env SEALED_TOKEN=AMBIENT sealed
  assert_failure 127
  assert [ ! -e "$BATS_TEST_TMPDIR/observed" ]
}

@test "malformed unsupported mismatched and non-executable runners all fail closed" {
  require_pty_fixture
  credential_set first op CLOSED_TOKEN
  credential_set second other OTHER_TOKEN
  make_stub closed-target "touch '$BATS_TEST_TMPDIR/closed-target-ran'"
  glolias add --credential op closed closed-target
  runner="$(credentials_dir)/op"

  chmod 0700 "$runner"
  cp "$(credentials_dir)/other" "$runner"
  chmod 0500 "$runner"
  run -127 --separate-stderr env CLOSED_TOKEN=AMBIENT closed
  assert_failure 127
  assert_stderr --partial "RunnerCredentialMismatch"
  assert [ ! -e "$BATS_TEST_TMPDIR/closed-target-ran" ]

  credential_set first op CLOSED_TOKEN
  chmod 0700 "$runner"
  "$COMPILED_FIXTURES/runner-mutate" unsupported "$runner"
  chmod 0500 "$runner"
  run -127 --separate-stderr closed
  assert_failure 127
  assert_stderr --partial "UnsupportedRunnerVersion"
  assert [ ! -e "$BATS_TEST_TMPDIR/closed-target-ran" ]

  credential_set first op CLOSED_TOKEN
  chmod 0700 "$runner"
  truncate -s -1 "$runner"
  chmod 0500 "$runner"
  run -127 --separate-stderr closed
  assert_failure 127
  assert [ ! -e "$BATS_TEST_TMPDIR/closed-target-ran" ]

  glolias add op closed-target
  run -127 --separate-stderr "$runner"
  assert_failure 127
  assert_stderr --partial "NotCredentialRunner"
  assert [ ! -e "$BATS_TEST_TMPDIR/closed-target-ran" ]

  credential_set first op CLOSED_TOKEN
  chmod 0400 "$runner"
  run -127 --separate-stderr closed
  assert_failure 127
  assert_stderr --partial "RunnerNotExecutable"
  assert [ ! -e "$BATS_TEST_TMPDIR/closed-target-ran" ]
}

@test "caller-supplied stale guard state cannot skip initial injection" {
  require_pty_fixture
  credential_set first op GUARDED_TOKEN
  glolias add --credential op guarded /usr/bin/env

  run env GLOLIAS_GUARD=guarded GUARDED_TOKEN=AMBIENT guarded
  assert_success
  assert_output --partial "GUARDED_TOKEN=$first_secret"
  refute_output --partial "GUARDED_TOKEN=AMBIENT"
}

@test "Credential Chains preserve stdin cwd argument boundaries and exit status" {
  require_pty_fixture
  credential_set first op TRANSPARENT_TOKEN
  make_stub transparent-target 'input=$(cat); printf "%s|%s|%s\n" "$PWD" "$1" "$input"; exit 23'
  glolias add --credential op transparent transparent-target
  work="$BATS_TEST_TMPDIR/working directory"
  mkdir "$work"

  cd "$work"
  run bash -c 'printf normal-stdin | transparent "a b"'
  assert_failure 23
  assert_output "$work|a b|normal-stdin"
}

@test "unbound Shims and direct Real commands receive no sealed Credential" {
  require_pty_fixture
  credential_set first op PRIVATE_TOKEN
  glolias add bound /usr/bin/env
  glolias add unbound /usr/bin/env
  glolias credential attach op bound

  run unbound
  assert_success
  refute_output --partial "PRIVATE_TOKEN=$first_secret"

  run /usr/bin/env
  assert_success
  refute_output --partial "PRIVATE_TOKEN=$first_secret"
}

@test "attach detach list remove and Alias removal preserve shared lifecycle boundaries" {
  require_pty_fixture
  credential_set first shared SHARED_TOKEN
  glolias add a /usr/bin/env
  glolias add b /usr/bin/env
  glolias credential attach shared a b

  run glolias credential list
  assert_success
  assert_output --partial $'shared\tSHARED_TOKEN\ta,b\tvalid'

  run --separate-stderr glolias credential remove shared
  assert_failure
  assert_stderr --partial "still attached"

  glolias credential detach shared a
  glolias remove b
  assert [ -f "$(credentials_dir)/shared" ]
  run glolias credential remove shared
  assert_success
  assert_output --partial "recovery requires"
  assert [ ! -e "$(credentials_dir)/shared" ]
  assert [ -L "$(shims_dir)/a" ]
}

@test "credential remove can clean unused metadata after its runner is already missing" {
  require_pty_fixture
  credential_set first lost LOST_TOKEN
  rm "$(credentials_dir)/lost"

  run glolias credential remove lost
  assert_success
  refute_config_line 'lost = "LOST_TOKEN"'
}

@test "Credential metadata changes require force and binding mutations preflight every Alias" {
  require_pty_fixture
  credential_set first op ORIGINAL_NAME
  glolias add a /usr/bin/env

  run --separate-stderr glolias credential set op CHANGED_NAME
  assert_failure
  assert_stderr --partial "use --force"
  assert_config_line 'op = "ORIGINAL_NAME"'

  run --separate-stderr glolias credential attach op a missing
  assert_failure
  assert_stderr --partial "Aliases do not exist"
  assert_config_line 'a.credentials = []'

  glolias credential attach op a
  run --separate-stderr glolias credential detach op a missing
  assert_failure
  assert_config_line 'a.credentials = ["op"]'

  credential_set second other OTHER_NAME
  run --separate-stderr "$COMPILED_FIXTURES/pty-secret" second "$GLOLIAS_BIN" credential set --force op CHANGED_NAME
  assert_success
  assert_config_line 'op = "CHANGED_NAME"'
  assert_config_line 'a.credentials = ["op"]'
}

@test "add --force replaces the complete binding list and omission clears it" {
  require_pty_fixture
  credential_set first one FIRST_TOKEN
  credential_set second two SECOND_TOKEN
  glolias add --credential one replaceable echo old
  glolias add --force --credential two replaceable echo new
  assert_config_line 'replaceable.credentials = ["two"]'

  glolias add --force replaceable echo final
  assert_config_line 'replaceable.credentials = []'
}

@test "sync refreshes a structurally valid runner created from an old executable base" {
  require_pty_fixture
  old_binary="$BATS_TEST_TMPDIR/old/glolias"
  mkdir -p "$(dirname "$old_binary")"
  cp "$GLOLIAS_BIN" "$old_binary"
  printf 'OLD-BASE' >>"$old_binary"
  chmod +x "$old_binary"
  "$COMPILED_FIXTURES/pty-secret" first "$old_binary" credential set op SYNC_TOKEN
  glolias add --credential op synced /usr/bin/env

  run glolias credential list
  assert_output --partial $'op\tSYNC_TOKEN\tsynced\tstale'
  run glolias sync
  assert_success
  run synced
  assert_success
  assert_output --partial "SYNC_TOKEN=$first_secret"
}

@test "Doctor reports runner damage read-only with secret-free remediation" {
  require_pty_fixture
  credential_set first op DOCTOR_TOKEN
  glolias add --credential op diagnosed /usr/bin/env
  runner="$(credentials_dir)/op"
  chmod 0700 "$runner"
  printf 'broken' >"$runner"
  chmod 0500 "$runner"
  before="$(sha256sum "$(config_file)" "$runner")"

  run glolias doctor
  assert_failure 1
  assert_output --partial "credential: op: runner invalid"
  assert_output --partial "glolias credential set"
  refute_output --partial "$first_secret"
  assert_equal "$before" "$(sha256sum "$(config_file)" "$runner")"

  run --separate-stderr glolias sync
  assert_failure
  assert_stderr --partial "credential set op"
  refute_stderr --partial "$first_secret"
}

@test "Doctor reports duplicate environments and orphan Credential artifacts" {
  require_pty_fixture
  credential_set first one DUPLICATE_DOCTOR_TOKEN
  credential_set second two DUPLICATE_DOCTOR_TOKEN
  glolias add --credential one --credential two duplicate /usr/bin/env
  touch "$(credentials_dir)/orphan-artifact"

  run glolias doctor
  assert_failure 1
  assert_output --partial "alias duplicate: duplicate environment providers"
  assert_output --partial "credential orphan: orphan-artifact"
  refute_output --partial "$first_secret"
  refute_output --partial "$second_secret"
}

@test "version 1 dispatch remains byte-stable until a successful mutation" {
  mkdir -p "$(dirname "$(config_file)")"
  printf '%s\n' 'version = 1' '' '[aliases]' 'legacy = ["echo", "legacy-ok"]' >"$(config_file)"
  link_unknown_shim legacy
  before="$(sha256sum "$(config_file)")"

  run legacy
  assert_success
  assert_output "legacy-ok"
  assert_equal "$before" "$(sha256sum "$(config_file)")"

  glolias add modern echo modern-ok
  assert_config_line 'version = 2'
  assert_config_line 'legacy.credentials = []'
}

@test "credential mutations reject a symlinked credentials directory" {
  require_pty_fixture
  outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside" "$(dirname "$(credentials_dir)")"
  ln -s "$outside" "$(credentials_dir)"

  run --separate-stderr credential_set first op SAFE_TOKEN
  assert_failure
  assert_output --partial "credentials directory is not a real directory"
  run find "$outside" -mindepth 1
  assert_success
  refute_output
}
