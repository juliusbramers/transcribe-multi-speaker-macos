#!/bin/sh
# The packaging check: install → setup → transcribe → uninstall under a temporary HOME, then a scan
# that nothing is left behind. Uses the tarball scripts/release.sh put in dist/.
#   scripts/package-check.sh <work folder> <audio file> [preset]
# The work folder gets the temp HOME and the transcript; it must be empty or not exist yet.
# Downloads the preset's models (fast: ~575 MB) into the temp HOME.
#
# Removes, as `tmsm uninstall` does, the account's ~/Library/Caches/tmsm and
# ~/Library/HTTPStorages/tmsm (macOS puts these in the account home even when $HOME points
# elsewhere). A temp HOME doesn't isolate the login Keychain, so the check refuses to run while a
# Keychain item "tmsm" exists: uninstall would delete a real installation's token.
set -eu
cd "$(dirname "$0")/.."
work="${1:?usage: scripts/package-check.sh <work folder> <audio file> [preset]}"
audio="${2:?usage: scripts/package-check.sh <work folder> <audio file> [preset]}"
preset="${3:-fast}"

if security find-generic-password -s tmsm >/dev/null 2>&1; then
  echo "a Keychain item \"tmsm\" exists (a real installation's token); not running" >&2
  exit 1
fi
[ ! -e "$work" ] || [ -z "$(ls -A "$work")" ] || { echo "$work is not empty" >&2; exit 1; }
tarball="$(ls dist/tmsm-*-macos-arm64.tar.gz 2>/dev/null | head -1)"
[ -n "$tarball" ] || { echo "no tarball in dist/; run scripts/release.sh first" >&2; exit 1; }
mkdir -p "$work/home" "$work/unpack" "$work/out"
work="$(cd "$work" && pwd)"
account="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')"
marker="$work/start-marker"
touch "$marker"

step() { printf '\n==> %s\n' "$1"; }
# Every tmsm call sees only the temp HOME, a login zsh (so the PATH line is what finds tmsm).
# The command is fixed text; values are passed as arguments ($1, $2, …), never spliced in.
in_home() {
  cmd="$1"; shift
  env -i HOME="$work/home" SHELL=/bin/zsh USER="$(id -un)" TERM=dumb /bin/zsh -lc "$cmd" zsh "$@"
}

step "unpack and check like the install line"
cp "$tarball" dist/SHA256SUMS "$work/unpack/"
(cd "$work/unpack" && f="$(basename "$tarball")" && grep " $f\$" SHA256SUMS | shasum -a 256 -c - \
  && tar -xzf "$f")
folder="$(ls -d "$work"/unpack/tmsm-*-macos-arm64)"

step "install"
env -i HOME="$work/home" SHELL=/bin/zsh PATH=/usr/bin:/bin "$folder/tmsm" install
rm -rf "$work/unpack"
[ -x "$work/home/.tmsm/tmsm" ] || { echo "not installed" >&2; exit 1; }
grep -q '# tmsm$' "$work/home/.zprofile" || { echo "no PATH line" >&2; exit 1; }
in_home 'command -v tmsm'

step "setup --preset $preset"
in_home 'tmsm setup --preset "$1" --keep-unused' "$preset"

step "transcribe"
in_home 'tmsm "$1" --output "$2" --json' "$audio" "$work/out/"
ls "$work/out"/*.md >/dev/null

step "uninstall"
in_home 'tmsm uninstall --yes'

step "scan"
left=0
if [ -n "$(ls -A "$work/home")" ]; then
  echo "left in the temp HOME:"; find "$work/home" -mindepth 1; left=1
fi
for p in "$account/Library/Caches/tmsm" "$account/Library/HTTPStorages/tmsm" "$account/.tmsm"; do
  if [ -e "$p" ]; then echo "left: $p"; left=1; fi
done
if security find-generic-password -s tmsm >/dev/null 2>&1; then
  echo "left: Keychain item tmsm"; left=1
fi
# Anything else named tmsm that appeared during the run where processes keep per-app state.
# (Folders like Mail or Containers are left out: reading them can raise privacy prompts.)
found=""
for d in Caches HTTPStorages "Application Support" Preferences Logs WebKit Cookies "Saved Application State"; do
  [ -d "$account/Library/$d" ] || continue
  found="$found$(find "$account/Library/$d" -maxdepth 3 -newer "$marker" -iname '*tmsm*' 2>/dev/null || true)"
done
if [ -n "$found" ]; then echo "new in ~/Library:"; echo "$found"; left=1; fi
rm -f "$marker"
[ "$left" = 0 ] || exit 1
echo "nothing left behind (transcript kept in $work/out)"
