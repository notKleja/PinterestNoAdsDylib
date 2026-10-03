#!/bin/zsh
set -euo pipefail

if [[ $# != 3 ]]; then
  print -u2 'usage: package_noads.sh INPUT_APP ENTITLEMENT_REFERENCE_APP OUTPUT_ROOT'
  exit 2
fi

root="${0:a:h}"
input_app="${1:a}"
reference_app="${2:a}"
output_root="${3:a}"
output_app="$output_root/Payload/Pinterest.app"
output_ipa="$output_root/Pinterest-14.38-noads.ipa"
filter_dylib="$root/build/libPinterestProbe.dylib"
injector="$root/build/macho-inject"
validator="$root/tools/validate_macho.sh"
load_path='@executable_path/Frameworks/libPinterestProbe.dylib'

die() {
  print -u2 "package_noads: $1"
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist" 2>/dev/null
}

[[ -d "$input_app" ]] || die 'input app is missing'
[[ -d "$reference_app" ]] || die 'reference app is missing'
[[ -f "$filter_dylib" ]] || die 'build the iOS dylib first'
[[ -x "$injector" ]] || die 'build the injector first'
[[ -x "$validator" ]] || die 'Mach-O validator is missing'
[[ ! -e "$output_root" ]] || die 'output root already exists'

for app in "$input_app" "$reference_app"; do
  [[ "$(plist_value "$app" CFBundleIdentifier)" == pinterest ]] ||
    die "unexpected bundle identifier in $app"
  [[ "$(plist_value "$app" CFBundleShortVersionString)" == 14.38 ]] ||
    die "unexpected version in $app"
  [[ "$(plist_value "$app" CFBundleVersion)" == 2 ]] ||
    die "unexpected build in $app"
  [[ "$(plist_value "$app" CFBundleExecutable)" == Pinterest ]] ||
    die "unexpected executable in $app"
done

main="$input_app/Pinterest"
"$validator" "$main" || die 'input main executable is not clear thin arm64'
uuid=$(otool -l "$main" |
  awk '/LC_UUID/{p=1;next} p && $1=="uuid" && !found {print $2;found=1;p=0}')
[[ "$uuid" == '8DDF19C3-6AEC-33DF-ADDF-3BF468B29451' ]] ||
  die 'input main executable UUID does not match Pinterest 14.38'
[[ -z "$(find "$input_app" -type d -name SC_Info -print -quit)" ]] ||
  die 'input app still contains FairPlay SC_Info'

macho_count=0
for candidate in "$input_app"/**/*(.N); do
  if file "$candidate" | grep -q 'Mach-O'; then
    (( macho_count += 1 ))
    "$validator" "$candidate" ||
      die "encrypted, universal, or unverifiable Mach-O: ${candidate#$input_app/}"
  fi
done
[[ "$macho_count" == 29 ]] ||
  die "expected 29 Mach-O components, found $macho_count"

mkdir -p "$output_root/Payload"
ditto "$input_app" "$output_app"
cp "$filter_dylib" "$output_app/Frameworks/libPinterestProbe.dylib"
"$injector" "$output_app/Pinterest" "$load_path"

signing_tmp=$(mktemp -d)
trap 'rm -rf "$signing_tmp"' EXIT

sign_target() {
  local target="$1"
  local reference="$2"
  local entitlement_policy="$3"
  local entitlements="$signing_tmp/entitlements.plist"
  local signed_entitlements="$signing_tmp/signed-entitlements.plist"
  rm -f "$entitlements"
  rm -f "$signed_entitlements"
  if [[ -e "$reference" ]] && \
      codesign -d --entitlements :- "$reference" 2>/dev/null | \
      plutil -convert xml1 -o "$entitlements" -- - 2>/dev/null; then
    codesign --force --sign - --timestamp=none \
      --entitlements "$entitlements" "$target"
    codesign -d --entitlements :- "$target" 2>/dev/null | \
      plutil -convert xml1 -o "$signed_entitlements" -- - 2>/dev/null ||
      die "could not read signed entitlements from $target"
    cmp -s <(plutil -p "$entitlements") <(plutil -p "$signed_entitlements") ||
      die "signed entitlements differ from the reference for $target"
  else
    [[ "$entitlement_policy" == optional ]] ||
      die "required entitlements are unavailable from $reference"
    codesign --force --sign - --timestamp=none "$target"
  fi
}

for dylib in "$output_app"/Frameworks/*.dylib(N); do
  relative="${dylib#$output_app/}"
  sign_target "$dylib" "$reference_app/$relative" optional
done

for framework in "$output_app"/Frameworks/*.framework(N); do
  relative="${framework#$output_app/}"
  sign_target "$framework" "$reference_app/$relative" optional
done

for extension in "$output_app"/PlugIns/*.appex(N); do
  relative="${extension#$output_app/}"
  sign_target "$extension" "$reference_app/$relative" required
done

sign_target "$output_app" "$reference_app" required
codesign --verify --deep --strict --verbose=2 "$output_app"

(
  cd "$output_root"
  ditto -c -k --sequesterRsrc --keepParent Payload "$output_ipa"
)
unzip -tq "$output_ipa"
print "$output_ipa"
