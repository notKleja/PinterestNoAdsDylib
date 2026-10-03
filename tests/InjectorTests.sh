#!/bin/zsh
set -euo pipefail

root="${0:a:h:h}"
work="$root/build/injector-test"
mkdir -p "$work"

fixture="$work/fixture"
patched="$work/fixture-patched"
injector="$root/build/macho-inject"
mutator="$root/build/injector-fixture-mutator"
load_path='@executable_path/Frameworks/libPinterestProbe.dylib'

print 'int main(void) { return 0; }' | \
    xcrun clang -arch arm64 -Wl,-headerpad,0x4000 -x c - -o "$fixture"
cp "$fixture" "$patched"

text_offset=$(otool -l "$fixture" | awk '
    $1 == "sectname" && $2 == "__text" { in_text = 1; next }
    in_text && $1 == "offset" { print $2; exit }
')
text_size_hex=$(otool -l "$fixture" | awk '
    $1 == "sectname" && $2 == "__text" { in_text = 1; next }
    in_text && $1 == "size" { print $2; exit }
')
text_size=$((text_size_hex))
before=$(dd if="$patched" bs=1 skip="$text_offset" count="$text_size" 2>/dev/null | shasum -a 256)

"$injector" "$patched" "$load_path"
"$injector" "$patched" "$load_path"

count=$(otool -L "$patched" | grep -F -c "$load_path")
[[ "$count" == 1 ]] || { print -u2 "FAIL: expected one injected load command"; exit 1; }
after=$(dd if="$patched" bs=1 skip="$text_offset" count="$text_size" 2>/dev/null | shasum -a 256)
[[ "$before" == "$after" ]] || { print -u2 "FAIL: injector changed __text"; exit 1; }

no_padding="$work/fixture-no-padding"
print 'int main(void) { return 0; }' | xcrun clang -arch arm64 -x c - -o "$no_padding"
no_padding_before=$(shasum -a 256 "$no_padding")
if "$injector" "$no_padding" "$load_path" 2>/dev/null; then
    print -u2 'FAIL: injector accepted a Mach-O without enough padding'
    exit 1
fi
[[ "$no_padding_before" == "$(shasum -a 256 "$no_padding")" ]] || {
    print -u2 'FAIL: rejected no-padding input was modified'; exit 1;
}

wrong_arch="$work/fixture-x86_64"
print 'int main(void) { return 0; }' | \
    xcrun clang -arch x86_64 -Wl,-headerpad,0x4000 -x c - -o "$wrong_arch"
if "$injector" "$wrong_arch" "$load_path" 2>/dev/null; then
    print -u2 'FAIL: injector accepted the wrong architecture'
    exit 1
fi

truncated="$work/fixture-truncated-segment"
cp "$fixture" "$truncated"
"$mutator" "$truncated" truncated-segment
if "$injector" "$truncated" "$load_path" 2>/dev/null; then
    print -u2 'FAIL: injector accepted a truncated segment command'
    exit 1
fi

equal_boundary="$work/fixture-equal-boundary"
cp "$fixture" "$equal_boundary"
"$mutator" "$equal_boundary" equal-boundary
equal_before=$(shasum -a 256 "$equal_boundary")
if "$injector" "$equal_boundary" "$load_path" 2>/dev/null; then
    print -u2 'FAIL: injector overwrote a section at the load-command boundary'
    exit 1
fi
[[ "$equal_before" == "$(shasum -a 256 "$equal_boundary")" ]] || {
    print -u2 'FAIL: rejected boundary input was modified'; exit 1;
}

print 'PASS: injector preserves __text and rejects unsafe Mach-O layouts'
