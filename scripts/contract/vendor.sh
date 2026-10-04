#!/bin/sh
# Copies the board contract from a commit of the Hermes desktop/daemon repo:
# the schema, its golden fixtures, where they came from and their checksums.
#
#   scripts/contract/vendor.sh <path to the desktop repo> <commit>
#       vendor; then run scripts/contract/generate-swift.sh and the tests
#   scripts/contract/vendor.sh --check
#       fail if a vendored file was changed by hand since it was vendored
set -eu
cd "$(dirname "$0")/../.."

if [ "${1:-}" = "--check" ]; then
  # The checksums are the lines after "sha256:" in SOURCE, paths relative to contract/.
  sums=$(sed -n '/^sha256:$/,$p' contract/SOURCE | sed 1d)
  [ -n "$sums" ] || { echo "contract/SOURCE has no checksums. Re-vendor with scripts/contract/vendor.sh." >&2; exit 1; }
  listed=$(printf '%s\n' "$sums" | awk '{print $2}' | sort)
  present=$(cd contract && { echo board.schema.json; ls fixtures/board/*.json; } | sort)
  if [ "$listed" != "$present" ]; then
    echo "contract/ files differ from those listed in contract/SOURCE. Re-vendor instead of editing by hand." >&2
    exit 1
  fi
  if ! (cd contract && printf '%s\n' "$sums" | shasum -a 256 -c --quiet -); then
    echo "A vendored contract file was edited by hand. Change it in the desktop repo and re-vendor." >&2
    exit 1
  fi
  echo "Vendored contract files match contract/SOURCE."
  exit 0
fi

repo=$1
commit=$2
full=$(git -C "$repo" rev-parse "$commit^{commit}")
if ! git -C "$repo" merge-base --is-ancestor "$full" origin/main 2>/dev/null; then
  echo "warning: $full is not on the desktop repo's origin/main; re-vendor from main once it merges." >&2
fi
rm -rf contract/fixtures/board
mkdir -p contract/fixtures/board
git -C "$repo" show "$full:contract/board.schema.json" > contract/board.schema.json
for path in $(git -C "$repo" ls-tree --name-only "$full" crates/bus/fixtures/board/); do
  git -C "$repo" show "$full:$path" > "contract/fixtures/board/$(basename "$path")"
done
{
  printf 'board.schema.json and fixtures/board/ come from the Hermes repo at\n%s\n' "$full"
  printf '(contract/board.schema.json and crates/bus/fixtures/board/).\n'
  printf 'Refresh with scripts/contract/vendor.sh; never edit these files by hand.\n\nsha256:\n'
  (cd contract && shasum -a 256 board.schema.json fixtures/board/*.json)
} > contract/SOURCE
echo "Vendored the board contract from $full."
