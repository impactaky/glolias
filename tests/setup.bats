#!/usr/bin/env bats

load test_helper/common

environment_file() {
  printf "%s\n" "$XDG_CONFIG_HOME/environment.d/60-glolias.conf"
}

enable_systemd_user_fact() {
  mkdir -p "$XDG_RUNTIME_DIR/systemd"
}

@test "setup addition preview reports exact targets and changes nothing" {
  printf '%s' 'export KEEP=profile' >"$HOME/.profile"
  printf '%s\n' '# keep zprofile' >"$HOME/.zprofile"
  glolias add gh echo WRAP

  profile_before="$(sha256sum "$HOME/.profile")"
  zprofile_before="$(sha256sum "$HOME/.zprofile")"
  config_before="$(sha256sum "$(config_file)")"
  shim_before="$(readlink "$(shims_dir)/gh")"
  path_before="$PATH"

  run glolias setup

  assert_success
  assert_output --partial "setup: read-only preview addition plan (linux)"
  assert_output --partial "path: $HOME/.profile"
  assert_output --partial "path: $HOME/.zprofile"
  assert_output --partial "managed-content-begin"
  assert_output --partial "# >>> glolias setup v1 >>>"
  assert_output --partial "Non-systemd Linux session"
  assert_output --partial "no files changed"
  assert_equal "$profile_before" "$(sha256sum "$HOME/.profile")"
  assert_equal "$zprofile_before" "$(sha256sum "$HOME/.zprofile")"
  assert_equal "$config_before" "$(sha256sum "$(config_file)")"
  assert_equal "$shim_before" "$(readlink "$(shims_dir)/gh")"
  assert_equal "$path_before" "$PATH"
  assert [ ! -e "$(environment_file)" ]
}

@test "systemd addition preview includes the exact environment.d file and remains read-only" {
  enable_systemd_user_fact
  path_before="$PATH"

  run glolias setup

  assert_success
  assert_output --partial "path: $(environment_file)"
  assert_output --partial "PATH=$(shims_dir)"
  assert_output --partial '${PATH:+:${PATH}}'
  assert [ ! -e "$HOME/.profile" ]
  assert [ ! -e "$HOME/.zprofile" ]
  assert [ ! -e "$(environment_file)" ]
  assert_equal "$path_before" "$PATH"
}

@test "setup apply does not mutate when the Setup Plan cannot be written" {
  enable_systemd_user_fact

  run --separate-stderr /bin/sh -c 'exec "$1" setup --apply 1>&-' sh "$GLOLIAS_BIN"

  assert_failure 1
  assert [ ! -e "$HOME/.profile" ]
  assert [ ! -e "$HOME/.zprofile" ]
  assert [ ! -e "$(environment_file)" ]
}

@test "setup rejects extra arguments and duplicate authorization flags with usage status" {
  run --separate-stderr glolias setup extra
  assert_equal "$status" 2
  refute_output
  assert_stderr --partial "glolias setup"

  run --separate-stderr glolias setup --apply --apply
  assert_equal "$status" 2
  refute_output
  assert_stderr --partial "expected only [--remove] [--apply]"
}

@test "setup rejects empty or relative environment roots before preview or apply can mutate" {
  safe_home="$HOME"
  safe_config="$XDG_CONFIG_HOME"
  safe_data="$XDG_DATA_HOME"
  unsafe_cwd="$BATS_TEST_TMPDIR/unsafe-cwd"
  mkdir -p "$unsafe_cwd"
  printf '%s' 'profile bytes' >"$safe_home/.profile"
  printf '%s' 'zprofile bytes' >"$safe_home/.zprofile"
  profile_before="$(sha256sum "$safe_home/.profile")"
  zprofile_before="$(sha256sum "$safe_home/.zprofile")"
  path_before="$PATH"

  cases=(
    "|$safe_config|$safe_data|HOME"
    "relative-home|$safe_config|$safe_data|HOME"
    "$safe_home||$safe_data|XDG_CONFIG_HOME"
    "$safe_home|relative-config|$safe_data|XDG_CONFIG_HOME"
    "$safe_home|$safe_config||XDG_DATA_HOME"
    "$safe_home|$safe_config|relative-data|XDG_DATA_HOME"
  )

  cd "$unsafe_cwd"
  for mode in preview apply
  do
    setup_args=()
    if [ "$mode" = apply ]
    then
      setup_args=(--apply)
    fi

    for test_case in "${cases[@]}"
    do
      IFS='|' read -r case_home case_config case_data expected_name <<<"$test_case"
      run env \
        HOME="$case_home" \
        XDG_CONFIG_HOME="$case_config" \
        XDG_DATA_HOME="$case_data" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        "$GLOLIAS_BIN" setup "${setup_args[@]}"

      assert_failure 1
      assert_output --partial "glolias setup: $expected_name must resolve to a non-empty absolute path"
      assert_equal "$profile_before" "$(sha256sum "$safe_home/.profile")"
      assert_equal "$zprofile_before" "$(sha256sum "$safe_home/.zprofile")"
      assert_equal "$path_before" "$PATH"
      assert [ ! -e "$safe_config/environment.d/60-glolias.conf" ]
      assert [ ! -e "$safe_data/glolias/shims" ]
      assert [ ! -e "$unsafe_cwd/relative-home" ]
      assert [ ! -e "$unsafe_cwd/relative-config" ]
      assert [ ! -e "$unsafe_cwd/relative-data" ]
    done
  done
}

@test "setup apply is atomic per file, idempotent, and PATH evaluation is duplicate-free" {
  enable_systemd_user_fact
  printf '%s' 'export KEEP=profile' >"$HOME/.profile"
  printf '%s\n' '# keep zprofile' >"$HOME/.zprofile"
  path_before="$PATH"
  profile_mode_before="$(stat -c '%a' "$HOME/.profile")"
  zprofile_mode_before="$(stat -c '%a' "$HOME/.zprofile")"

  run glolias setup --apply

  assert_success
  assert_output --partial "apply complete"
  assert_output --partial "current PATH and OS session were not changed"
  assert_equal "$(grep -c '^# >>> glolias setup v1 >>>$' "$HOME/.profile")" "1"
  assert_equal "$(grep -c '^# >>> glolias setup v1 >>>$' "$HOME/.zprofile")" "1"
  assert_equal "$(stat -c '%a' "$HOME/.profile")" "$profile_mode_before"
  assert_equal "$(stat -c '%a' "$HOME/.zprofile")" "$zprofile_mode_before"
  expected_environment="PATH=$(shims_dir)"'${PATH:+:${PATH}}'
  assert_equal "$(cat "$(environment_file)")" "$expected_environment"
  assert_equal "$path_before" "$PATH"

  profile_hash="$(sha256sum "$HOME/.profile")"
  zprofile_hash="$(sha256sum "$HOME/.zprofile")"
  environment_hash="$(sha256sum "$(environment_file)")"

  run glolias setup --apply

  assert_success
  assert_output --partial "everything was already in the requested state"
  assert_equal "$profile_hash" "$(sha256sum "$HOME/.profile")"
  assert_equal "$zprofile_hash" "$(sha256sum "$HOME/.zprofile")"
  assert_equal "$environment_hash" "$(sha256sum "$(environment_file)")"

  run env -i HOME="$HOME" PATH="/usr/bin:/bin" /bin/sh -c '. "$HOME/.profile"; . "$HOME/.profile"; printf "%s" "$PATH"'
  assert_success
  assert_output "$(shims_dir):/usr/bin:/bin"
}

@test "remove preview is read-only and remove apply restores exact outside bytes" {
  enable_systemd_user_fact
  original_profile='export PATH=/unrelated:$PATH'
  original_zprofile='# unrelated zsh bytes'
  printf '%s' "$original_profile" >"$HOME/.profile"
  printf '%s' "$original_zprofile" >"$HOME/.zprofile"
  glolias setup --apply

  profile_hash="$(sha256sum "$HOME/.profile")"
  zprofile_hash="$(sha256sum "$HOME/.zprofile")"
  environment_hash="$(sha256sum "$(environment_file)")"

  run glolias setup --remove

  assert_success
  assert_output --partial "read-only preview removal"
  assert_output --partial "action: remove"
  assert_equal "$profile_hash" "$(sha256sum "$HOME/.profile")"
  assert_equal "$zprofile_hash" "$(sha256sum "$HOME/.zprofile")"
  assert_equal "$environment_hash" "$(sha256sum "$(environment_file)")"

  run glolias setup --remove --apply

  assert_success
  assert_equal "$(cat "$HOME/.profile")" "$original_profile"
  assert_equal "$(cat "$HOME/.zprofile")" "$original_zprofile"
  assert [ ! -e "$(environment_file)" ]

  run glolias setup --remove --apply
  assert_success
  assert_output --partial "everything was already in the requested state"
  assert_equal "$(cat "$HOME/.profile")" "$original_profile"
  assert_equal "$(cat "$HOME/.zprofile")" "$original_zprofile"
}

@test "malformed and duplicate profile markers conflict before every mutation" {
  enable_systemd_user_fact

  printf '%s\n' '# >>> glolias setup v1 >>>' >"$HOME/.profile"
  run glolias setup --apply
  assert_failure
  assert_output --partial "malformed or duplicate"
  assert_output --partial "no files changed"
  assert [ ! -e "$HOME/.zprofile" ]
  assert [ ! -e "$(environment_file)" ]

  printf '%s\n' \
    '# >>> glolias setup v1 >>>' \
    '# <<< glolias setup v1 <<<' \
    '# >>> glolias setup v1 >>>' \
    '# <<< glolias setup v1 <<<' >"$HOME/.profile"
  run glolias setup --apply
  assert_failure
  assert_output --partial "malformed or duplicate"
  assert [ ! -e "$HOME/.zprofile" ]
  assert [ ! -e "$(environment_file)" ]
}

@test "symlink and non-regular profile targets conflict without being followed" {
  enable_systemd_user_fact
  printf '%s' 'outside bytes' >"$BATS_TEST_TMPDIR/outside-profile"
  ln -s "$BATS_TEST_TMPDIR/outside-profile" "$HOME/.profile"
  mkdir "$HOME/.zprofile"
  outside_hash="$(sha256sum "$BATS_TEST_TMPDIR/outside-profile")"

  run glolias setup --apply

  assert_failure
  assert_output --partial "profile target is a symlink"
  assert_output --partial "profile target is not a regular file"
  assert_equal "$outside_hash" "$(sha256sum "$BATS_TEST_TMPDIR/outside-profile")"
  assert [ -L "$HOME/.profile" ]
  assert [ -d "$HOME/.zprofile" ]
  assert [ ! -e "$(environment_file)" ]
}

@test "unexpected owned-file content and unsafe paths block the whole apply" {
  enable_systemd_user_fact
  mkdir -p "$(dirname "$(environment_file)")"
  printf '%s\n' 'PATH=/user-owned' >"$(environment_file)"
  owned_hash="$(sha256sum "$(environment_file)")"

  run glolias setup --apply

  assert_failure
  assert_output --partial "unexpected content in a glolias-owned file"
  assert_equal "$owned_hash" "$(sha256sum "$(environment_file)")"
  assert [ ! -e "$HOME/.profile" ]
  assert [ ! -e "$HOME/.zprofile" ]

  rm "$(environment_file)"
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data-\$unsafe"
  run glolias setup --apply
  assert_failure
  assert_output --partial "cannot be represented losslessly"
  assert [ ! -e "$HOME/.profile" ]
  assert [ ! -e "$HOME/.zprofile" ]
  assert [ ! -e "$(environment_file)" ]
}

@test "spaces and quoting characters are represented losslessly" {
  enable_systemd_user_fact
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data with 'quote&<"

  run glolias setup --apply

  assert_success
  expected_environment="PATH=$(shims_dir)"'${PATH:+:${PATH}}'
  assert_equal "$(cat "$(environment_file)")" "$expected_environment"
  run env -i HOME="$HOME" PATH="/usr/bin:/bin" /bin/sh -c '. "$HOME/.profile"; . "$HOME/.profile"; printf "%s" "$PATH"'
  assert_success
  assert_output "$(shims_dir):/usr/bin:/bin"
}

@test "a later filesystem failure reports applied failed and pending actions then reruns cleanly" {
  enable_systemd_user_fact
  blocker="$BATS_TEST_TMPDIR/config-blocker"
  printf '%s' 'not a directory' >"$blocker"
  export XDG_CONFIG_HOME="$blocker/child"

  run glolias setup --apply

  assert_failure
  assert_output --partial "applied: $HOME/.profile"
  assert_output --partial "failed: $(environment_file)"
  assert_output --partial "pending: $HOME/.zprofile"
  assert [ -f "$HOME/.profile" ]
  assert [ ! -e "$HOME/.zprofile" ]

  rm "$blocker"
  run glolias setup --apply

  assert_success
  assert [ -f "$HOME/.profile" ]
  assert [ -f "$HOME/.zprofile" ]
  assert [ -f "$(environment_file)" ]
  assert_equal "$(grep -c '^# >>> glolias setup v1 >>>$' "$HOME/.profile")" "1"
  assert_equal "$(grep -c '^# >>> glolias setup v1 >>>$' "$HOME/.zprofile")" "1"
}
