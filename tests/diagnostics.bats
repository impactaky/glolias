#!/usr/bin/env bats

load test_helper/common

@test "doctor succeeds for a healthy current-shell setup" {
  glolias add gh echo WRAP
  glolias add gs git status

  run glolias doctor

  assert_success
  assert_output --partial "config: ok"
  assert_output --partial "shims_dir: ok"
  assert_output --partial "doctor: ok"
  assert_output --partial "current shell environment only"
}

@test "doctor reports a missing config as an inconsistency" {
  mkdir -p "$(shims_dir)"

  run glolias doctor

  assert_failure 1
  assert_output --partial "config: error: ConfigNotFound"
}

@test "doctor reports a config parse error as an inconsistency" {
  write_bad_config

  run glolias doctor

  assert_failure 1
  assert_output --partial "config: error"
}

@test "doctor reports a missing shims directory and configured shim" {
  glolias add gh echo WRAP
  rm "$(shims_dir)/gh"
  rmdir "$(shims_dir)"

  run glolias doctor

  assert_failure 1
  assert_output --partial "shims_dir: missing"
  assert_output --partial "shim: gh: missing"
  assert_output --partial "glolias sync"
}

@test "doctor reports when the shims path is not a directory" {
  glolias add gh echo WRAP
  rm "$(shims_dir)/gh"
  rmdir "$(shims_dir)"
  touch "$(shims_dir)"

  run glolias doctor

  assert_failure 1
  assert_output --partial "shims_dir: not a directory (regular file)"
}

@test "doctor flags when the shims directory is absent from PATH" {
  glolias add gh echo WRAP

  run env PATH="$TEST_BIN:/usr/bin:/bin" "$GLOLIAS_BIN" doctor

  assert_failure 1
  assert_output --partial "path: shims_dir is not on PATH"
}

@test "doctor flags a real command shadowing the shim" {
  make_stub gh 'echo real-gh'
  glolias add gh echo WRAP

  run env PATH="$TEST_BIN:$(shims_dir):/usr/bin:/bin" "$GLOLIAS_BIN" doctor

  assert_failure 1
  assert_output --partial "shadowing: gh is shadowed"
}

@test "doctor lists orphan symlinks" {
  glolias add gh echo WRAP
  link_unknown_shim orphan

  run glolias doctor

  assert_failure 1
  assert_output --partial "orphan: orphan"
  assert_output --partial "glolias sync"
}

@test "doctor reports a missing configured shim by Alias name" {
  glolias add gh echo WRAP
  rm "$(shims_dir)/gh"

  run glolias doctor

  assert_failure 1
  assert_output --partial "shim: gh: missing"
  assert_output --partial "glolias sync"
}

@test "doctor reports a dangling configured shim" {
  glolias add gh echo WRAP
  ln -sf "$BATS_TEST_TMPDIR/does-not-exist" "$(shims_dir)/gh"

  run glolias doctor

  assert_failure 1
  assert_output --partial "shim: gh: dangling or unresolvable symlink"
  assert_output --partial "glolias sync"
}

@test "doctor reports a configured shim pointing at another binary" {
  glolias add gh echo WRAP
  make_stub old-glolias 'echo old'
  ln -sf "$TEST_BIN/old-glolias" "$(shims_dir)/gh"

  run glolias doctor

  assert_failure 1
  assert_output --partial "shim: gh: points to a different glolias binary"
  assert_output --partial "$TEST_BIN/old-glolias"
  assert_output --partial "glolias sync"
}

@test "doctor reports regular files and directories blocking configured shims" {
  glolias add gh echo WRAP
  glolias add gs git status
  rm "$(shims_dir)/gh" "$(shims_dir)/gs"
  touch "$(shims_dir)/gh"
  mkdir "$(shims_dir)/gs"

  run glolias doctor

  assert_failure 1
  assert_output --partial "shim: gh: not a symlink (regular file)"
  assert_output --partial "shim: gs: not a symlink (directory)"
  assert_output --partial "glolias sync"
}

@test "doctor reports every inspectable inconsistency in one run" {
  glolias add gh echo WRAP
  glolias add gs git status
  make_stub gh 'echo real-gh'
  ln -sf "$BATS_TEST_TMPDIR/does-not-exist" "$(shims_dir)/gh"
  rm "$(shims_dir)/gs"
  link_unknown_shim orphan

  run env PATH="$TEST_BIN:$(shims_dir):/usr/bin:/bin" "$GLOLIAS_BIN" doctor

  assert_failure 1
  assert_output --partial "shadowing: gh is shadowed"
  assert_output --partial "shim: gh: dangling or unresolvable symlink"
  assert_output --partial "shim: gs: missing"
  assert_output --partial "orphan: orphan"
  assert_output --partial "glolias sync"
}

@test "doctor does not change config, shims, or the caller PATH" {
  glolias add gh echo WRAP
  config_before="$(sha256sum "$(config_file)")"
  shim_before="$(readlink "$(shims_dir)/gh")"
  path_before="$PATH"

  run glolias doctor

  assert_success
  assert_equal "$config_before" "$(sha256sum "$(config_file)")"
  assert_equal "$shim_before" "$(readlink "$(shims_dir)/gh")"
  assert_equal "$path_before" "$PATH"
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
