#!/usr/bin/env bats

load test_helper/common

@test "gh wraps a command transparently" {
  glolias add gh echo WRAP

  run gh hi

  assert_success
  assert_output "WRAP hi"
}

@test "quoted arguments stay single arguments" {
  make_stub arg-dump 'printf "<%s>
" "$@"'
  glolias add gh arg-dump

  run gh "a b"

  assert_success
  assert_output "<a b>"
}

@test "re-entering through PATH runs the real command once" {
  install_fixture_stub real_gh.sh gh
  install_fixture_stub op_stub.sh op-stub
  glolias add gh op-stub gh

  run gh X

  assert_success
  assert_output "REAL:X:G=gh"
}

@test "self-wrap runs the real command once" {
  install_fixture_stub real_gh.sh gh
  glolias add gh gh --default

  run gh X

  assert_success
  assert_output "REAL:--default X:G=gh"
}

@test "the rerouted command owns the exit code" {
  glolias add gf false

  run gf

  assert_failure 1
}

@test "missing and non-executable targets use shell-like exit codes" {
  glolias add missing does-not-exist
  run -127 --separate-stderr missing
  assert_failure 127
  assert_stderr --partial "command not found"

  printf '#!/usr/bin/env bash
exit 0
' >"$TEST_BIN/noexec"
  chmod 0644 "$TEST_BIN/noexec"
  glolias add bad noexec
  run --separate-stderr bad
  assert_failure 126
  assert_stderr --partial "permission denied"
}

@test "Ctrl-C passes through to the real command" {
  require_c_fixture
  glolias add nap "$COMPILED_FIXTURES/sig-target" "$BATS_TEST_TMPDIR/real.pid"

  nap &
  local launched=$!

  for _ in $(seq 50)
  do
    [ -s "$BATS_TEST_TMPDIR/real.pid" ] && break
    sleep 0.05
  done

  run cat "$BATS_TEST_TMPDIR/real.pid"
  assert_success
  assert_equal "$output" "$launched"

  kill -INT "$launched"
  set +e
  wait "$launched"
  local wait_status=$?
  set -e
  assert_equal "$wait_status" 130
}

@test "a shim with no config entry points users at sync" {
  glolias add known echo ok
  link_unknown_shim unknown

  run -127 --separate-stderr unknown

  assert_failure 127
  assert_stderr --partial "run 'glolias sync'"
}

@test "empty argv0 fails loudly" {
  require_c_fixture

  run -127 --separate-stderr "$COMPILED_FIXTURES/empty_argv" "$GLOLIAS_BIN"

  assert_failure 127
  assert_stderr --partial "cannot determine alias name"
}

@test "unparseable config fails loudly during dispatch" {
  write_bad_config
  link_unknown_shim gh

  run -127 --separate-stderr gh

  assert_failure 127
  assert_stderr --partial "unable to load config"
}

@test "missing config fails loudly during dispatch" {
  link_unknown_shim gh

  run -127 --separate-stderr gh

  assert_failure 127
  assert_stderr --partial "unable to load config"
}
