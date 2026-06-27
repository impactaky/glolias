#!/usr/bin/env bats

load test_helper/common

@test "every top-level help entry point shows the overview" {
  for args in "" "help" "-h" "--help"
  do
    if [ -z "$args" ]
    then
      run --separate-stderr glolias
    else
      run --separate-stderr glolias "$args"
    fi

    assert_success
    refute_stderr
    assert_output --partial "glolias "
    assert_output --partial "global aliases as PATH-resident shims"
    assert_output --partial "add [--force] <name> <cmd>..."
    assert_output --partial "list [--plain]"
    assert_output --partial "doctor"
    assert_output --partial "Run 'glolias <command> --help' for details on a command."
  done
}

@test "every command exposes help through all help forms" {
  for cmd in add remove sync list path doctor
  do
    run --separate-stderr glolias "$cmd" --help
    assert_success
    refute_stderr
    assert_output --partial "glolias $cmd"
    assert_output --partial "usage: glolias $cmd"
    assert_output --partial "-h, --help"

    run --separate-stderr glolias "$cmd" -h
    assert_success
    refute_stderr
    assert_output --partial "glolias $cmd"

    run --separate-stderr glolias help "$cmd"
    assert_success
    refute_stderr
    assert_output --partial "glolias $cmd"
  done
}

@test "add help is leading-only and later --help is stored" {
  run --separate-stderr glolias add --help
  assert_success
  refute_stderr
  assert_output --partial "Tokens after <name> are stored verbatim"

  run glolias add gh curl --help
  assert_success
  assert_config_line 'gh = ["curl", "--help"]'
}

@test "doctor and list help include their important notes" {
  run --separate-stderr glolias help doctor
  assert_success
  refute_stderr
  assert_output --partial "current shell environment only"

  run --separate-stderr glolias list --help
  assert_success
  refute_stderr
  assert_output --partial "--plain"
}

@test "parse-error help goes to stderr and fails" {
  run --separate-stderr glolias list extra

  assert_failure
  refute_output
  assert_stderr --partial "Invalid argument 'extra'"
  assert_stderr --partial "glolias list"
}
