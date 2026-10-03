#!/bin/zsh
set -euo pipefail

root="${0:a:h:h}"
cd "$root"

allowed_paths=(
  .gitignore
  LICENSE
  NOTICE
  README.md
  build.sh
  package_noads.sh
  scripts/check_public_tree.sh
  src/PinterestProbe.m
  tests/FilterTests.m
  tests/InjectorFixtureMutator.c
  tests/InjectorTests.sh
  tests/MachOPreflightTests.sh
  tests/PackagePreflightTests.sh
  tests/ProbeTests.m
  tests/PublicTreeAuditTests.sh
  tests/ReleasePolicyTests.sh
  tools/macho_inject.c
  tools/validate_macho.sh
)

is_allowed_path() {
  local candidate="$1"
  local allowed
  for allowed in "${allowed_paths[@]}"; do
    [[ "$candidate" == "$allowed" ]] && return 0
  done
  return 1
}

for tracked_file in "${(@f)$(git ls-files)}"; do
  is_allowed_path "$tracked_file" || {
    print -u2 "public-tree: unapproved tracked path: $tracked_file"
    exit 1
  }
done
for allowed in "${allowed_paths[@]}"; do
  git ls-files --error-unmatch "$allowed" >/dev/null 2>&1 || {
    print -u2 "public-tree: required tracked path is missing: $allowed"
    exit 1
  }
done

audit_tmp=$(mktemp -d)
trap 'rm -rf "$audit_tmp"' EXIT
secret_pattern='/'"Users"'/|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|'"PASSWORD"'=|'"SECRET"'=|'"TOKEN"'='

scan_blob() {
  local object_id="$1"
  local object_path="$2"
  local scope="$3"
  local blob="$audit_tmp/blob"
  local matches="$audit_tmp/matches"
  local blob_size
  local kind
  local scan_exit

  is_allowed_path "$object_path" || {
    print -u2 "public-tree: unapproved $scope path: $object_path"
    exit 1
  }
  blob_size=$(git cat-file -s "$object_id")
  (( blob_size <= 5242880 )) || {
    print -u2 "public-tree: $scope blob exceeds 5 MiB: $object_path"
    exit 1
  }
  git cat-file blob "$object_id" > "$blob"
  kind=$(file -b "$blob")
  if [[ "$kind" == *Mach-O* ]]; then
    print -u2 "public-tree: tracked Mach-O $scope blob is forbidden: $object_path"
    exit 1
  fi

  set +e
  strings -a "$blob" | awk -v pattern="$secret_pattern" '
    $0 ~ pattern { print; found=1 }
    END { exit(found ? 0 : 1) }
  ' > "$matches"
  scan_exit=$?
  set -e
  if (( scan_exit == 0 )); then
    cat "$matches" >&2
    print -u2 "public-tree: local path or credential pattern in $scope blob: $object_path"
    exit 1
  fi
  (( scan_exit == 1 )) || {
    print -u2 "public-tree: secret scan failed for $scope blob: $object_path"
    exit 1
  }
}

while read -r mode object_id stage tracked_file; do
  [[ -n "$object_id" && -n "$tracked_file" ]] || continue
  scan_blob "$object_id" "$tracked_file" index
done < <(git ls-files --stage)

while IFS= read -r object_line; do
  [[ "$object_line" == *' '* ]] || continue
  object_id="${object_line%% *}"
  object_path="${object_line#* }"
  [[ "$(git cat-file -t "$object_id")" == blob ]] || continue
  scan_blob "$object_id" "$object_path" history
done < <(git rev-list --objects --all)

print 'PASS: public tree contains only approved source artifacts'
