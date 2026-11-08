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

step "release build ($version, arm64)"
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
if grep -q '"mlx-swift"' Package.resolved 2>/dev/null && ! ls "$dist/$name"/*.metallib >/dev/null 2>&1 \
  && ! ls -d "$dist/$name"/*.bundle >/dev/null 2>&1; then
  echo "the package uses MLX but no .metallib or resource bundle is beside the binary in $bin" >&2
  exit 1
fi
cp NOTICE README.md "$dist/$name/"
[ -f LICENSE ] && cp LICENSE "$dist/$name/"
ls -l "$dist/$name"

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
  echo "gh release create v$version --repo $repo --target $(git rev-parse HEAD) --title \"tmsm $version\" --notes \"$notes\" $dist/$tarball $dist/SHA256SUMS"
  echo "(or, if v$version exists without these assets: gh release upload v$version --repo $repo <files>, never --clobber)"
  exit 0
fi

step "publish v$version to $repo"
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
  gh release create "v$version" --repo "$repo" --target "$(git rev-parse HEAD)" \
    --title "tmsm $version" --notes "$notes" "$dist/$tarball" "$dist/SHA256SUMS"
fi
echo "published: https://github.com/$repo/releases/tag/v$version"
