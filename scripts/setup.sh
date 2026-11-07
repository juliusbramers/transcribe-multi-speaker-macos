#!/bin/sh
# One-time setup after cloning: enable the repo's git hooks.
set -eu
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
command -v betterleaks >/dev/null 2>&1 || echo "Recommended: brew install betterleaks"
echo "Git hooks enabled (.githooks)."
