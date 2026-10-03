#!/bin/sh
# Bumps the app's version in Config/Version.xcconfig.
#
#   scripts/bump-version.sh          build number only (every build for a phone)
#   scripts/bump-version.sh patch    0.2.0 -> 0.2.1, and the build number
#   scripts/bump-version.sh minor    0.2.1 -> 0.3.0, and the build number
#   scripts/bump-version.sh major    0.3.0 -> 1.0.0, and the build number
set -eu
cd "$(dirname "$0")/.."
file=Config/Version.xcconfig
part=${1:-build}

version=$(sed -n 's/^MARKETING_VERSION = //p' "$file")
build=$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$file")
IFS=. read -r major minor patch <<VERSION
$version
VERSION

case $part in
  build) ;;
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
  *) echo "usage: $0 [build|patch|minor|major]" >&2; exit 2 ;;
esac

new="$major.$minor.$patch"
build=$((build + 1))
sed -i '' -e "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $new/" \
  -e "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $build/" "$file"
echo "$version -> $new ($build)"
