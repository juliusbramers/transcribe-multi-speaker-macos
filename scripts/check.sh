#!/bin/sh
# The one local check (there is no hosted CI): secrets, formatting, build, tests.
# Needs only the Command Line Tools, no Xcode.
#   scripts/check.sh         run everything
#   scripts/check.sh --fix   format Swift sources in place first
set -eu
cd "$(dirname "$0")/.."

step() { printf '\n==> %s\n' "$1"; }

if [ "${1:-}" = "--fix" ]; then
  step "swift format (fix)"
  git ls-files -z -- '*.swift' | xargs -0 -r swift format --in-place
fi

step "secrets (betterleaks, full history)"
if command -v betterleaks >/dev/null 2>&1; then
  betterleaks git --no-banner -l warn
else
  echo "betterleaks not installed, skipping. Install: brew install betterleaks" >&2
fi

if [ ! -f Package.swift ]; then
  printf "\nNo Package.swift yet, skipping format, build and tests.\n"
  exit 0
fi

step "swift format lint"
git ls-files -z -- '*.swift' | xargs -0 -r swift format lint --strict

step "swift build"
swift build

# Tests are an executable target, not `swift test`: XCTest and Swift Testing need
# full Xcode, and this repo builds with the Command Line Tools alone.
step "tests (swift run selftest)"
if [ -d Sources/selftest ]; then swift run selftest; else echo "No Sources/selftest yet, skipping."; fi

printf '\nAll checks passed.\n'
