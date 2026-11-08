#!/bin/sh
# Build and package a tmsm release locally. There is no hosted CI.
#   scripts/release.sh            dry run: release build, tarball, SHA256SUMS, checks; nothing leaves the Mac
#   scripts/release.sh --publish  also creates GitHub release v<version> with those two files
#
# Output: dist/tmsm-<version>-macos-arm64.tar.gz and dist/SHA256SUMS. The tarball holds one folder,
# tmsm-<version>-macos-arm64/, with the tmsm executable, the Metal library and resource bundles
# SwiftPM put beside it, NOTICE and README.md. The version comes from Sources/TMSM/Version.swift.
#
# --publish never replaces an asset: if release v<version> already has a file of the same name,
# it stops. Publishing needs a clean tree whose HEAD is on origin/main, and `gh` logged in.
set -eu
cd "$(dirname "$0")/.."

publish=0
case "${1:-}" in
  "") ;;
  --publish) publish=1 ;;
  *) echo "usage: scripts/release.sh [--publish]" >&2; exit 2 ;;
esac

repo="juliusbramers/transcribe-multi-speaker-macos"
version="$(sed -n 's/.*string = "\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' Sources/TMSM/Version.swift)"
[ -n "$version" ] || { echo "no version in Sources/TMSM/Version.swift" >&2; exit 1; }
name="tmsm-$version-macos-arm64"
tarball="$name.tar.gz"
dist="$PWD/dist"

step() { printf '\n==> %s\n' "$1"; }

if [ "$publish" = 1 ]; then
  step "publish preconditions"
  [ -z "$(git status --porcelain)" ] || { echo "the working tree is not clean" >&2; exit 1; }
  git fetch -q origin main
  git merge-base --is-ancestor HEAD origin/main || { echo "HEAD is not on origin/main" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "gh is not logged in" >&2; exit 1; }
fi

built="$(git rev-parse HEAD)"

step "release build ($version, arm64, commit ${built%"${built#????????????}"})"
swift build -c release --arch arm64 --product tmsm
bin="$(swift build -c release --arch arm64 --show-bin-path)"

step "stage $name/"
rm -rf "$dist"
mkdir -p "$dist/$name"
cp "$bin/tmsm" "$dist/$name/"
# The Metal library and resource bundles SwiftPM places beside the executable.
for item in "$bin"/*.metallib "$bin"/*.bundle "$bin"/*.resources; do
  [ -e "$item" ] && cp -R "$item" "$dist/$name/"
done
# MLX needs its full Metal library beside tmsm (the bundle's default.metallib is incomplete).
if grep -q 'mlx-swift' Package.resolved 2>/dev/null; then
  lib="$dist/$name/mlx.metallib"
  [ -f "$lib" ] && [ "$(stat -f %z "$lib")" -gt 50000000 ] || {
    echo "the package uses MLX but $bin has no full mlx.metallib (run scripts/build-metallib.sh release)" >&2
    exit 1
  }
fi
cp NOTICE README.md "$dist/$name/"
cp scripts/uninstall.sh "$dist/$name/uninstall.sh"
chmod +x "$dist/$name/uninstall.sh"
[ -f LICENSE ] && cp LICENSE "$dist/$name/"
ls -l "$dist/$name"

step "macOS 15 gate: every shipped Mach-O"
# arm64 only, minimum macOS 15 or lower, every non-system dependency shipped beside tmsm and
# found through @executable_path/@loader_path, no rpath into this Mac's developer tools.
fail() { echo "gate: $*" >&2; exit 1; }
stage="$dist/$name"
machos="$(find "$stage" -type f | while IFS= read -r f; do
  if file -b "$f" | grep -q Mach-O; then printf '%s\n' "$f"; fi
done)"
[ -n "$machos" ] || fail "no Mach-O found"
printf '%s\n' "$machos" | while IFS= read -r f; do
  short="${f#"$stage"/}"
  [ "$(lipo -archs "$f")" = arm64 ] || fail "$short is not arm64-only: $(lipo -archs "$f")"
  minos="$(vtool -show-build "$f" | awk '$1 == "minos" { print $2; exit }')"
  [ -n "$minos" ] || fail "$short has no minimum macOS"
  awk -v v="$minos" 'BEGIN { split(v, a, "."); exit !(a[1] < 15 || (a[1] == 15 && a[2] + 0 == 0)) }' \
    || fail "$short needs macOS $minos, more than 15.0"
  changed=0
  for rp in $(otool -l "$f" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }'); do
    case "$rp" in
      /usr/lib/swift | @executable_path | @executable_path/* | @loader_path | @loader_path/*) ;;
      *) install_name_tool -delete_rpath "$rp" "$f" && changed=1 && echo "$short: dropped rpath $rp" ;;
    esac
  done
  if ! otool -l "$f" | awk '$1 == "path" { print $2 }' | grep -qx '@executable_path'; then
    case "$short" in
      *.dylib) ;;
      *) install_name_tool -add_rpath @executable_path "$f" && changed=1 ;;
    esac
  fi
  for dep in $(otool -L "$f" | tail -n +2 | awk '{ print $1 }'); do
    case "$dep" in
      /System/* | /usr/lib/*) ;;
      @rpath/*) [ -f "$stage/${dep#@rpath/}" ] || fail "$short needs $dep, which is not shipped beside tmsm" ;;
      *) fail "$short depends on $dep, outside the system and the package" ;;
    esac
  done
  # install_name_tool invalidates the signature; arm64 code must be signed (ad hoc) to run.
  if [ "$changed" = 1 ]; then codesign --force --sign - "$f" 2>/dev/null || fail "can't re-sign $short"; fi
  echo "$short: arm64, minos $minos, dependencies resolve"
done

step "smoke test"
got="$("$dist/$name/tmsm" --version)"
[ "$got" = "$version" ] || { echo "tmsm --version says $got, expected $version" >&2; exit 1; }
"$dist/$name/tmsm" --help >/dev/null
echo "tmsm --version: $got"

step "tarball and SHA256SUMS"
(cd "$dist" && COPYFILE_DISABLE=1 tar --no-mac-metadata --uid 0 --gid 0 -czf "$tarball" "$name")
(cd "$dist" && shasum -a 256 "$tarball" > SHA256SUMS)
# The install line's own check, on the files as they will be uploaded.
(cd "$dist" && grep " $tarball\$" SHA256SUMS | shasum -a 256 -c -)
rm -rf "$dist/$name"
ls -l "$dist"

notes="tmsm $version for macOS on Apple silicon. Unsigned: install with the line in README.md, which checks the download against SHA256SUMS."

if [ "$publish" = 0 ]; then
  step "dry run: publishing would run"
  echo "gh release create v$version --repo $repo --target $built --title \"tmsm $version\" --notes \"$notes\" $dist/$tarball $dist/SHA256SUMS"
  echo "(or, if v$version exists without these assets: gh release upload v$version --repo $repo <files>, never --clobber)"
  exit 0
fi

step "publish v$version to $repo"
# The tag must name the commit these files were built from; never attach them to another.
tag_commit="$(git ls-remote origin "refs/tags/v$version^{}" | cut -f1)"
[ -n "$tag_commit" ] || tag_commit="$(git ls-remote origin "refs/tags/v$version" | cut -f1)"
if [ -n "$tag_commit" ] && [ "$tag_commit" != "$built" ]; then
  echo "refused: tag v$version is $tag_commit on origin, but this build is $built" >&2
  exit 1
fi
if gh release view "v$version" --repo "$repo" >/dev/null 2>&1; then
  published="$(gh release view "v$version" --repo "$repo" --json assets --jq '.assets[].name')"
  for file in "$tarball" SHA256SUMS; do
    if printf '%s\n' "$published" | grep -Fxq "$file"; then
      echo "refused: release v$version already has $file. Published assets are never replaced." >&2
      exit 1
    fi
  done
  gh release upload "v$version" --repo "$repo" "$dist/$tarball" "$dist/SHA256SUMS"
else
  gh release create "v$version" --repo "$repo" --target "$built" \
    --title "tmsm $version" --notes "$notes" "$dist/$tarball" "$dist/SHA256SUMS"
fi
echo "published: https://github.com/$repo/releases/tag/v$version"
