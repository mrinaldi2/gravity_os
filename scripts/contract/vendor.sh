#!/bin/sh
# Copies the board contract from a commit of the Hermes desktop/daemon repo:
# the schema, its golden fixtures, and where they came from.
#
#   scripts/contract/vendor.sh <path to the desktop repo> <commit>
# Then run scripts/contract/generate-swift.sh and the tests.
set -eu
repo=$1
commit=$2
cd "$(dirname "$0")/../.."
full=$(git -C "$repo" rev-parse "$commit^{commit}")
rm -rf contract/fixtures/board
mkdir -p contract/fixtures/board
git -C "$repo" show "$full:contract/board.schema.json" > contract/board.schema.json
for path in $(git -C "$repo" ls-tree --name-only "$full" crates/bus/fixtures/board/); do
  git -C "$repo" show "$full:$path" > "contract/fixtures/board/$(basename "$path")"
done
printf 'board.schema.json and fixtures/board/ come from the Hermes repo at\n%s\n(contract/board.schema.json and crates/bus/fixtures/board/).\nRefresh with scripts/contract/vendor.sh.\n' "$full" > contract/SOURCE
echo "Vendored the board contract from $full."
