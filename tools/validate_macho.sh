#!/bin/zsh
set -euo pipefail

[[ $# == 1 ]] || { print -u2 'usage: validate_macho.sh MACHO'; exit 2; }
binary="$1"
[[ -f "$binary" ]] || { print -u2 "macho-check: missing file: $binary"; exit 1; }

description=$(file -b "$binary")
[[ "$description" == *'Mach-O 64-bit'*' arm64' &&
   "$description" != *'universal binary'* ]] || {
  print -u2 "macho-check: expected one thin arm64 slice: $binary"
  exit 1
}

cryptids=("${(@f)$(otool -l "$binary" 2>/dev/null |
  awk '$1=="cryptid" { print $2 }')}" )
[[ ${#cryptids} == 1 && "${cryptids[1]}" == 0 ]] || {
  print -u2 "macho-check: expected exactly one cryptid=0 record: $binary"
  exit 1
}
