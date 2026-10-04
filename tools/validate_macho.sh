#!/bin/zsh
set -euo pipefail

[[ $# == 1 ]] || { print -u2 'usage: validate_macho.sh MACHO'; exit 2; }
binary="$1"
[[ -f "$binary" ]] || { print -u2 "macho-check: missing file: $binary"; exit 1; }

arch_output=$(lipo -archs "$binary" 2>/dev/null) || {
  print -u2 "macho-check: could not read Mach-O architectures: $binary"
  exit 1
}
archs=("${(@s: :)arch_output}")
(( ${#archs} > 0 )) || {
  print -u2 "macho-check: no Mach-O architectures found: $binary"
  exit 1
}

has_arm64=0
for arch in "${archs[@]}"; do
  case "$arch" in
    arm64) has_arm64=1 ;;
    arm64e) ;;
    *)
      print -u2 "macho-check: unsupported architecture $arch: $binary"
      exit 1
      ;;
  esac

  cryptids=("${(@f)$(otool -arch "$arch" -l "$binary" 2>/dev/null |
    awk '$1=="cryptid" { print $2 }')}" )
  [[ ${#cryptids} == 1 && "${cryptids[1]}" == 0 ]] || {
    print -u2 "macho-check: $arch must contain exactly one cryptid=0 record: $binary"
    exit 1
  }
done

(( has_arm64 == 1 )) || {
  print -u2 "macho-check: an arm64 slice is required: $binary"
  exit 1
}
