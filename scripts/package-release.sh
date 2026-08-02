#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: scripts/package-release.sh <X.Y.Z> <output-directory>" >&2
  exit 2
}

if [ "$#" -ne 2 ]
then
  usage
fi

version="$1"
output_arg="$2"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
then
  echo "package-release: version must match X.Y.Z exactly" >&2
  exit 2
fi

repo_dir="$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manifest_version="$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",[[:space:]]*$/\1/p' "$repo_dir/build.zig.zon")"
if [ -z "$manifest_version" ] || [ "$manifest_version" != "$version" ]
then
  echo "package-release: requested version $version does not match build.zig.zon version ${manifest_version:-<missing>}" >&2
  exit 1
fi

mkdir -p "$output_arg"
output_dir="$(unset CDPATH; cd -- "$output_arg" && pwd)"
specs=(
  "x86_64-linux-musl|linux|x86_64"
  "aarch64-linux-musl|linux|aarch64"
  "x86_64-macos.14.0|macos|x86_64"
  "aarch64-macos.14.0|macos|aarch64"
)
archive_names=()

for spec in "${specs[@]}"
do
  IFS='|' read -r zig_target release_os release_arch <<<"$spec"
  archive_name="glolias-v$version-$release_os-$release_arch.tar.gz"
  if [ -e "$output_dir/$archive_name" ]
  then
    echo "package-release: refusing to overwrite $output_dir/$archive_name" >&2
    exit 1
  fi
  archive_names+=("$archive_name")
done
if [ -e "$output_dir/SHA256SUMS" ]
then
  echo "package-release: refusing to overwrite $output_dir/SHA256SUMS" >&2
  exit 1
fi

work_dir="$(mktemp -d "$output_dir/.glolias-package.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

for spec in "${specs[@]}"
do
  IFS='|' read -r zig_target release_os release_arch <<<"$spec"
  archive_name="glolias-v$version-$release_os-$release_arch.tar.gz"
  prefix="$work_dir/prefix-$release_os-$release_arch"
  stage="$work_dir/stage-$release_os-$release_arch"

  zig build \
    -Dtarget="$zig_target" \
    -Doptimize=ReleaseFast \
    -Dcpu=baseline \
    -p "$prefix"

  mkdir -p "$stage"
  install -m 0755 "$prefix/bin/glolias" "$stage/glolias"
  install -m 0644 "$repo_dir/README.md" "$stage/README.md"
  install -m 0644 "$repo_dir/LICENSE" "$stage/LICENSE"
  tar \
    --sort=name \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --mtime=@0 \
    -czf "$output_dir/$archive_name" \
    -C "$stage" \
    glolias README.md LICENSE
done

(
  cd "$output_dir"
  sha256sum "${archive_names[@]}" >SHA256SUMS
  sha256sum --check SHA256SUMS
)

printf 'created %s\n' "${archive_names[@]}" "SHA256SUMS"
