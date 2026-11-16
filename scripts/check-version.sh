#!/bin/bash
# Checks the single source of truth for the version: the VERSION file, the
# release notes that ship with that version, and — when a tag is passed — that
# the tag names the same version.
#
#   scripts/check-version.sh            # CI: VERSION and its notes exist
#   scripts/check-version.sh v0.9.1     # release: the tag matches VERSION
#
# The release workflow passes $GITHUB_REF_NAME so a tag that does not match
# stops the run before anything is built or published.
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:-}"

fail() {
  echo "error: $*" >&2
  exit 1
}

VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || true)"
[ -n "$VERSION" ] || fail "VERSION is missing or empty"

# Plain numbers only: UpdateChecker parses the same shape from a release tag.
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || fail "VERSION '$VERSION' is not X.Y.Z with plain numbers"

IFS=. read -r major minor patch <<<"$VERSION"

# scripts/build-app.sh turns the version into CFBundleVersion as
# major*10000 + minor*100 + patch, so the build number rises with the version.
# That only holds while minor and patch stay below 100.
(( minor < 100 && patch < 100 )) \
  || fail "minor and patch must be below 100 for the CFBundleVersion scheme"

[ -f "docs/releases/$VERSION.md" ] || fail "missing docs/releases/$VERSION.md"

if [ -n "$TAG" ]; then
  [ "$TAG" = "v$VERSION" ] || fail "tag $TAG does not match VERSION v$VERSION"
fi

echo "version $VERSION ok${TAG:+ (tag $TAG)}"
