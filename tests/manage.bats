#!/usr/bin/env bats

load test_helper/common

@test "add writes a config entry and creates its shim" {
  glolias add gh op plugin run -- gh

  assert_config_line 'gh = ["op", "plugin", "run", "--", "gh"]'
  refute_config_line 'shims_dir = '
  assert_shim_points_to_current_binary gh
}

@test "leading-dash command tokens are stored verbatim" {
  glolias add gs git -c color.ui=always status
  glolias add hh curl --help

  assert_config_line 'gs = ["git", "-c", "color.ui=always", "status"]'
  assert_config_line 'hh = ["curl", "--help"]'
}

@test "re-adding is idempotent unless tokens conflict" {
  glolias add gh echo WRAP
  run glolias add gh echo WRAP
  assert_success

  run --separate-stderr glolias add gh echo OTHER
  assert_failure
  assert_stderr --partial "use --force"

  run glolias add --force gh echo OTHER
  assert_success
  assert_config_line 'gh = ["echo", "OTHER"]'
}

@test "alias names reject reserved and degenerate forms" {
  for name in "glolias" "a/b" "" "-x"
  do
    run --separate-stderr glolias add "$name" echo value
    assert_failure
  done
}

@test "list shows aligned rows for people" {
  glolias add gf false
  glolias add gh echo WRAP
  glolias add g echo short
  glolias add gitlog echo long

  run glolias list

  assert_success
  assert_output $'ALIAS   COMMAND
g       echo short
gf      false
gh      echo WRAP
gitlog  echo long'
}

@test "list --plain keeps the script format" {
  glolias add gf false
  glolias add gh echo WRAP
  glolias add g echo short
  glolias add gitlog echo long

  run glolias list --plain

  assert_success
  assert_output $'g	echo short
gf	false
gh	echo WRAP
gitlog	echo long'
}

@test "empty list output distinguishes people from scripts" {
  run glolias list
  assert_success
  assert_output "ALIAS   COMMAND"

  run glolias list --plain
  assert_success
  refute_output
}

@test "path prints exactly the shims directory" {
  run glolias path

  assert_success
  assert_output "$(shims_dir)"
}

@test "remove deletes the config entry and shim" {
  glolias add bad noexec

  run glolias remove bad

  assert_success
  assert [ ! -L "$(shims_dir)/bad" ]
  refute_config_line 'bad = '
}

@test "removing an absent alias is an error" {
  glolias add known echo ok

  run --separate-stderr glolias remove absent

  assert_failure
  assert_stderr --partial "no alias 'absent'"
}
