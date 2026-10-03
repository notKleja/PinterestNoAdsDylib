#!/bin/zsh
set -euo pipefail

source_root="${0:a:h:h}"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

make_repo() {
  local name="$1"
  local repo="$test_root/$name"
  mkdir -p "$repo"
  (
    cd "$source_root"
    git checkout-index --all --prefix="$repo/"
  )
  (
    cd "$repo"
    git init -q -b main
    git config user.name AuditTest
    git config user.email audit@example.invalid
    git add -A
    git commit -q -m baseline
  )
  print "$repo"
}

expect_rejected() {
  local repo="$1"
  local expected="$2"
  local output="$test_root/output.txt"
  if (cd "$repo" && zsh scripts/check_public_tree.sh >"$output" 2>&1); then
    cat "$output"
    print -u2 "FAIL: audit accepted $expected"
    exit 1
  fi
  cat "$output"
}

mismatch_repo=$(make_repo index-mismatch)
unsafe_prefix='/'"Users"'/synthetic/private/path'
print "$unsafe_prefix" > "$mismatch_repo/README.md"
(cd "$mismatch_repo" && git add README.md && git show HEAD:README.md > README.md)
expect_rejected "$mismatch_repo" 'unsafe staged content hidden by a safe worktree'

unknown_repo=$(make_repo unknown-asset)
print 'PASS'"WORD=synthetic-not-a-secret" > "$unknown_repo/.env"
print 'synthetic asset' > "$unknown_repo/Assets.car"
(cd "$unknown_repo" && git add -f .env Assets.car)
expect_rejected "$unknown_repo" 'unexpected assets and secret-bearing files'

history_repo=$(make_repo forbidden-history)
mkdir -p "$history_repo/Payload/Pinterest.app"
print 'synthetic payload' > "$history_repo/Payload/Pinterest.app/asset.bin"
(
  cd "$history_repo"
  git add -f Payload/Pinterest.app/asset.bin
  git commit -q -m add-forbidden-fixture
  git rm -q Payload/Pinterest.app/asset.bin
  git commit -q -m remove-forbidden-fixture
)
expect_rejected "$history_repo" 'a deleted payload retained in reachable history'

print 'PASS: public-tree audit rejects index, asset, and history bypasses'
