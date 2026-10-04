#!/bin/zsh
set -euo pipefail

root="${0:a:h:h}"
work=$(mktemp -d)
filter="$root/build/libPinterestProbe.dylib"
filter_backup="$work/libPinterestProbe.dylib"
cp "$filter" "$filter_backup"
cleanup() {
  cp "$filter_backup" "$filter"
  rm -rf "$work"
}
trap cleanup EXIT
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

print 'int incompatible_filter(void) { return 0; }' | \
  xcrun clang -arch x86_64 -dynamiclib -x c - -o "$filter"
incompatible_output="$work/incompatible-output"
incompatible_log="$work/incompatible.log"
if zsh "$root/package_noads.sh" \
    "$work/not-pinterest.app" "$work/reference.app" "$incompatible_output" \
    >"$incompatible_log" 2>&1; then
  print -u2 'FAIL: packager accepted an incompatible filter dylib'
  exit 1
fi
grep -q 'filter dylib' "$incompatible_log" || {
  cat "$incompatible_log"
  print -u2 'FAIL: packager rejected another input before validating the filter dylib'
  exit 1
}
[[ ! -e "$incompatible_output" ]] || {
  print -u2 'FAIL: incompatible filter created an output root'
  exit 1
}

print 'PASS: package preflight rejects invalid app and filter before writing output'
