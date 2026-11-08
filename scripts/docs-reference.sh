#!/bin/sh
# Rewrites the "## Reference" section of docs/cli.md from the built binary: the exact output of
# each command below, run with an empty TMSM_HOME. selftest (SetupCases) fails when they differ.
#   swift build && scripts/docs-reference.sh
set -eu
cd "$(dirname "$0")/.."
bin="${1:-.build/debug/tmsm}"
doc=docs/cli.md
empty="$(mktemp -d)"
trap 'rm -rf "$empty"' EXIT
head="$(sed '/^## Reference$/,$d' "$doc")"
{
  printf '%s\n\n## Reference\n\n' "$head"
  echo "These blocks are the exact output of the command above each one, run with an empty \`TMSM_HOME\`."
  for args in "--help" "transcribe --help" "setup --help" "setup --list" "install --help" \
    "update --help" "uninstall --help"; do
    printf '\n### `tmsm %s`\n\n<!-- tmsm %s -->\n```text\n' "$args" "$args"
    # shellcheck disable=SC2086 # args are split on purpose
    env -i TMSM_HOME="$empty" PATH=/usr/bin:/bin "$bin" $args
    echo '```'
  done
} > "$doc.new"
mv "$doc.new" "$doc"
echo "updated $doc"
