#!/bin/zsh
set -euo pipefail

root="${0:a:h:h}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
validator="$root/tools/validate_macho.sh"
fixture="$root/build/libPinterestValidationFixture.dylib"

"$validator" "$fixture"

print 'int main(void) { return 0; }' | \
  xcrun clang -arch x86_64 -x c - -o "$work/x86_64"
lipo -create "$fixture" "$work/x86_64" \
  -output "$work/universal"

if "$validator" "$work/universal" >/dev/null 2>&1; then
  print -u2 'FAIL: validator accepted a universal Mach-O'
  exit 1
fi

print 'PASS: Mach-O preflight requires one clear thin-arm64 slice'
