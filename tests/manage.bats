#!/usr/bin/env bats

load test_helper/common

@test "add writes a config entry and creates its shim" {
  glolias add gh op plugin run -- gh

  assert_config_line 'gh.tokens = ["op", "plugin", "run", "--", "gh"]'
  refute_config_line 'shims_dir = '
  assert_shim_points_to_current_binary gh
}

@test "all supported Alias name boundary forms save and create shims" {
  for name in "a" "A0" "_local" "foo-bar"
  do
    glolias add "$name" echo "$name"
    assert_config_line "$name.tokens = [\"echo\", \"$name\"]"
    assert_shim_points_to_current_binary "$name"
  done
}

@test "leading-dash command tokens are stored verbatim" {
  glolias add gs git -c color.ui=always status
  glolias add hh curl --help

  assert_config_line 'gs.tokens = ["git", "-c", "color.ui=always", "status"]'
  assert_config_line 'hh.tokens = ["curl", "--help"]'
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
  assert_config_line 'gh.tokens = ["echo", "OTHER"]'
}

@test "unsupported Alias names fail before changing config or shims" {
  glolias add keep echo stable
  config_before="$(cat "$(config_file)")"
  shims_before="$(find "$(shims_dir)" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)"

  for name in "" "glolias" "-x" "a/b" "." "a b" "a:b" "é"
  do
    run --separate-stderr glolias add "$name" echo value

    assert_equal "$status" 2
    refute_output
    if [ -z "$name" ]
    then
      assert_stderr --partial "invalid alias name ''"
    elif [[ "$name" == -* ]]
    then
      assert_stderr --partial "Invalid argument '$name'"
    else
      assert_stderr --partial "invalid alias name '$name'"
    fi
    assert_stderr --partial "[A-Za-z0-9_][A-Za-z0-9_-]*"
    assert_equal "$(cat "$(config_file)")" "$config_before"
    assert_equal "$(find "$(shims_dir)" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)" "$shims_before"
  done
}

@test "foo.bar is a normal input error, not a serializer crash" {
  run --separate-stderr glolias add foo.bar echo value

  assert_equal "$status" 2
  refute_output
  assert_stderr --partial "invalid alias name 'foo.bar'"
  assert_stderr --partial "[A-Za-z0-9_][A-Za-z0-9_-]*"
  refute_stderr --partial "Double free"
  assert [ ! -e "$(config_file)" ]
  assert [ ! -e "$(shims_dir)/foo.bar" ]
}

@test "config save failure after Alias insertion exits normally" {
  glolias add keep echo stable
  chmod 0555 "$(dirname "$(config_file)")"

  run --separate-stderr glolias add unsaved echo value
  chmod 0755 "$(dirname "$(config_file)")"

  assert_equal "$status" 1
  refute_output
  refute_stderr --partial "error(DebugAllocator)"
  refute_stderr --partial "Double free"
  refute_stderr --partial "General protection exception"
  refute_stderr --partial "Segmentation fault"
  refute_config_line "unsaved.tokens = "
  assert [ ! -e "$(shims_dir)/unsaved" ]
}

@test "shim creation failure after Alias insertion exits normally" {
  mkdir -p "$(shims_dir)/blocked"

  run --separate-stderr glolias add blocked echo value

  assert_equal "$status" 1
  refute_output
  refute_stderr --partial "error(DebugAllocator)"
  refute_stderr --partial "Double free"
  refute_stderr --partial "General protection exception"
  refute_stderr --partial "Segmentation fault"
  refute_config_line 'blocked.tokens = ["echo", "value"]'
  assert [ ! -L "$(shims_dir)/blocked" ]
}

@test "add explains config directory creation failures" {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/read-only-config"
  mkdir "$XDG_CONFIG_HOME"
  chmod 0555 "$XDG_CONFIG_HOME"

  run --separate-stderr glolias add gh echo value
  chmod 0755 "$XDG_CONFIG_HOME"

  assert_failure 1
  refute_output
  assert_stderr --partial "glolias add: cannot create config directory '$XDG_CONFIG_HOME/glolias'"
  assert_stderr --partial "permission denied"
  refute_stderr --partial "MkdirFailed"
}

@test "add explains shims directory creation failures" {
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data-blocker"
  touch "$XDG_DATA_HOME"

  run --separate-stderr glolias add gh echo value

  assert_failure 1
  refute_output
  assert_stderr --partial "glolias add: cannot create shims directory '$XDG_DATA_HOME/glolias/shims'"
  assert_stderr --partial "a parent path is not a directory"
  refute_stderr --partial "MkdirFailed"
  refute_config_line 'gh.tokens = ["echo", "value"]'
}

@test "created directories remain 0755 with a permissive umask" {
  original_umask="$(umask)"
  umask 000
  glolias add gh echo value
  umask "$original_umask"

  config_mode="$(stat -c '%a' "$XDG_CONFIG_HOME/glolias" 2>/dev/null || stat -f '%Lp' "$XDG_CONFIG_HOME/glolias")"
  data_mode="$(stat -c '%a' "$XDG_DATA_HOME/glolias" 2>/dev/null || stat -f '%Lp' "$XDG_DATA_HOME/glolias")"
  shims_mode="$(stat -c '%a' "$(shims_dir)" 2>/dev/null || stat -f '%Lp' "$(shims_dir)")"

  assert_equal "$config_mode" 755
  assert_equal "$data_mode" 755
  assert_equal "$shims_mode" 755
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
  refute_config_line 'bad.tokens = '
}

@test "remove preflights a blocked Shim before changing the Alias" {
  glolias add blocked echo value
  rm "$(shims_dir)/blocked"
  mkdir "$(shims_dir)/blocked"

  run --separate-stderr glolias remove blocked

  assert_failure 1
  assert_config_line 'blocked.tokens = ["echo", "value"]'
  assert [ -d "$(shims_dir)/blocked" ]
}

@test "removing an absent alias is an error" {
  glolias add known echo ok

  run --separate-stderr glolias remove absent

  assert_failure
  assert_stderr --partial "no alias 'absent'"
}
