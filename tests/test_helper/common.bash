load test_helper/bats-support/load
load test_helper/bats-assert/load

setup_file() {
  bats_require_minimum_version 1.7.0

  : "${GLOLIAS_BIN:?zig build e2e must set GLOLIAS_BIN}"
  if [ ! -x "$GLOLIAS_BIN" ]
  then
    echo "GLOLIAS_BIN is not executable: $GLOLIAS_BIN" >&2
    return 1
  fi

  export REAL_PATH="$PATH"
  export FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  export COMPILED_FIXTURES="$BATS_FILE_TMPDIR/fixtures-bin"
  mkdir -p "$COMPILED_FIXTURES"

  export GLOLIAS_C_FIXTURES_AVAILABLE=0
  if command -v cc >/dev/null 2>&1
  then
    if cc -o "$COMPILED_FIXTURES/empty_argv" "$FIXTURES/empty_argv.c"
    then
      if cc -o "$COMPILED_FIXTURES/sig-target" "$FIXTURES/sig_target.c"
      then
        export GLOLIAS_C_FIXTURES_AVAILABLE=1
      fi
    fi
  fi
}

setup() {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
  export TEST_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$TEST_BIN"
  export PATH="$(shims_dir):$TEST_BIN:$REAL_PATH"
  hash -r
}

glolias() {
  "$GLOLIAS_BIN" "$@"
}

shims_dir() {
  printf "%s
" "$XDG_DATA_HOME/glolias/shims"
}

config_file() {
  printf "%s
" "$XDG_CONFIG_HOME/glolias/config.toml"
}

make_stub() {
  local name="$1"
  local body="$2"
  local path="$TEST_BIN/$name"
  printf "#!/usr/bin/env bash
%s
" "$body" >"$path"
  chmod +x "$path"
}

install_fixture_stub() {
  local fixture="$1"
  local name="$2"
  local path="$TEST_BIN/$name"
  cp "$FIXTURES/$fixture" "$path"
  chmod +x "$path"
}

link_unknown_shim() {
  local name="$1"
  mkdir -p "$(shims_dir)"
  ln -sf "$GLOLIAS_BIN" "$(shims_dir)/$name"
  hash -r
}

write_bad_config() {
  mkdir -p "$XDG_CONFIG_HOME/glolias"
  cp "$FIXTURES/bad_config.toml" "$(config_file)"
}

require_c_fixture() {
  if [ "${GLOLIAS_C_FIXTURES_AVAILABLE:-0}" != 1 ]
  then
    skip "cc is required to compile C e2e fixtures"
  fi
}

assert_config_line() {
  run grep -F "$1" "$(config_file)"
  assert_success
}

refute_config_line() {
  run grep -F "$1" "$(config_file)"
  assert_failure
}

assert_shim_points_to_current_binary() {
  local name="$1"
  run readlink "$(shims_dir)/$name"
  assert_success
  assert_output "$GLOLIAS_BIN"
}
