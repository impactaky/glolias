#!/usr/bin/env bats

load test_helper/common

@test "doctor notes that it sees only the current shell" {
  glolias add gh echo WRAP

  run glolias doctor

  assert_success
  assert_output --partial "current shell environment only"
}

@test "doctor flags when the shims directory is absent from PATH" {
  glolias add gh echo WRAP

  run env PATH="$TEST_BIN:/usr/bin:/bin" "$GLOLIAS_BIN" doctor

  assert_success
  assert_output --partial "path: shims_dir is not on PATH"
}

@test "doctor flags a real command shadowing the shim" {
  make_stub gh 'echo real-gh'
  glolias add gh echo WRAP

  run env PATH="$TEST_BIN:$(shims_dir):/usr/bin:/bin" "$GLOLIAS_BIN" doctor

  assert_success
  assert_output --partial "shadowing: gh is shadowed"
}

@test "doctor lists orphan symlinks" {
  glolias add gh echo WRAP
  link_unknown_shim orphan

  run glolias doctor

  assert_success
  assert_output --partial "orphan: orphan"
}

@test "doctor reports config parse errors" {
  write_bad_config

  run glolias doctor

  assert_failure 1
  assert_output --partial "config: error"
}

@test "sync rehydrates all configured shims" {
  glolias add gh echo WRAP
  glolias add gs git status
  rm "$(shims_dir)/gh" "$(shims_dir)/gs"

  run glolias sync

  assert_success
  assert_shim_points_to_current_binary gh
  assert_shim_points_to_current_binary gs
}

@test "sync prunes symlinks with no config entry" {
  glolias add gh echo WRAP
  link_unknown_shim orphan

  run glolias sync

  assert_success
  assert [ ! -L "$(shims_dir)/orphan" ]
}

@test "sync repoints dangling or stale shims at the current binary" {
  glolias add gh echo WRAP
  glolias add gs git status
  ln -sf /tmp/does-not-exist "$(shims_dir)/gh"
  make_stub old-glolias 'echo old'
  ln -sf "$TEST_BIN/old-glolias" "$(shims_dir)/gs"

  run glolias sync

  assert_success
  assert_shim_points_to_current_binary gh
  assert_shim_points_to_current_binary gs
}
