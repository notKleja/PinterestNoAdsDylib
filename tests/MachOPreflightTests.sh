#!/bin/zsh
set -euo pipefail

root="${0:a:h:h}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
validator="$root/tools/validate_macho.sh"
fixture="$root/build/libPinterestValidationFixture.dylib"

"$validator" "$fixture"

sdk=$(xcrun --sdk iphoneos --show-sdk-path)
print 'int compatibility_fixture(void) { return 0; }' | \
  xcrun clang -isysroot "$sdk" -target arm64e-apple-ios16.0 \
    -dynamiclib -x c - -o "$work/arm64e.dylib"
lipo -create "$fixture" "$work/arm64e.dylib" \
  -output "$work/arm64-arm64e.dylib"
"$validator" "$work/arm64-arm64e.dylib"

print 'int main(void) { return 0; }' | \
  xcrun clang -arch x86_64 -x c - -o "$work/x86_64"
lipo -create "$fixture" "$work/x86_64" \
  -output "$work/universal"

if "$validator" "$work/universal" >/dev/null 2>&1; then
  print -u2 'FAIL: validator accepted a universal Mach-O containing x86_64'
  exit 1
fi

print 'PASS: Mach-O preflight validates every arm64 and arm64e slice'
