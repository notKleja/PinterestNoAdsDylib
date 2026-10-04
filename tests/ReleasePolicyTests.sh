#!/bin/zsh
set -euo pipefail

[[ $# == 1 ]] || { print -u2 'usage: ReleasePolicyTests.sh DYLIB'; exit 2; }
library="$1"

nm -gj "$library" | grep -qx '_PIBAdFilterInstall'
nm -gj "$library" | grep -qx '_PIBAppGroupFallbackInstall'
nm -gj "$library" | grep -qx '_PIBProbeWriteInventory'

if strings -a "$library" | grep -Eq 'runtime-%@s\.json|metadata inventory'; then
  print -u2 'FAIL: release dylib contains automatic metadata-inventory behavior'
  exit 1
fi

print 'PASS: release dylib autostarts filter and app-group compatibility only'
