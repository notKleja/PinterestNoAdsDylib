#!/bin/zsh
set -euo pipefail

root="${0:a:h:h}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/not-pinterest.app" "$work/reference.app"
output="$work/output"

if zsh "$root/package_noads.sh" \
    "$work/not-pinterest.app" "$work/reference.app" "$output" \
    >/dev/null 2>&1; then
  print -u2 'FAIL: packager accepted an invalid app'
  exit 1
fi

[[ ! -e "$output" ]] || {
  print -u2 'FAIL: packager created output before preflight completed'
  exit 1
}

print 'PASS: package preflight rejects invalid input before writing output'
