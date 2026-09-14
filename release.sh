#!/bin/bash
# Cuts a release tarball and points the formula at it.
#
# The tarball is the committed tree plus server/release/public/client.js, which
# is generated rather than checked in. With it inside, building the app needs
# only clang, swift and an esbuild binary, and no Node toolchain at all.
#
#   --publish   tag the current commit, create the GitHub release, upload the
#               tarball
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
NAME="ruecksicht-$VERSION"
DIST="$ROOT/dist"
TARBALL="$DIST/$NAME.tar.gz"
REPO="$(git -C "$ROOT" remote get-url origin \
    | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"

# git archive ships HEAD, so anything uncommitted would be silently left out of
# the release while still sitting in the tree that was tested.
[ -z "$(git -C "$ROOT" status --porcelain)" ] || {
    echo "working tree is dirty -- commit before cutting a release" >&2; exit 1
}
git -C "$ROOT" rev-parse "v$VERSION" >/dev/null 2>&1 && {
    echo "tag v$VERSION already exists -- bump VERSION" >&2; exit 1
}

[ -d "$ROOT/server/node_modules" ] || (cd "$ROOT/server" && npm install)
(cd "$ROOT/server" && npm run build-client)

rm -rf "$DIST"
mkdir -p "$DIST/$NAME/server/release/public"
git -C "$ROOT" archive HEAD | tar -x -C "$DIST/$NAME"
cp "$ROOT/server/release/public/client.js" "$DIST/$NAME/server/release/public/client.js"
tar -C "$DIST" -czf "$TARBALL" "$NAME"
rm -rf "${DIST:?}/$NAME"

SHA="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
URL="https://github.com/$REPO/releases/download/v$VERSION/$NAME.tar.gz"
sed -i '' -E \
    -e "s#^  url \"https://github.com/.*/releases/.*\"#  url \"$URL\"#" \
    -e "s#^  sha256 \".*\"#  sha256 \"$SHA\"#" \
    "$ROOT/Formula/ruecksicht.rb"

echo "$TARBALL"
echo "  sha256 $SHA"
echo "  url    $URL"

if [ "$1" = "--publish" ]; then
    git -C "$ROOT" tag -a "v$VERSION" -m "Rücksicht $VERSION"
    git -C "$ROOT" push origin "v$VERSION"
    gh release create "v$VERSION" "$TARBALL" \
        --repo "$REPO" \
        --title "Rücksicht $VERSION" \
        --notes "Build from source: see the README. Homebrew: brew tap $REPO https://github.com/$REPO && brew install ruecksicht"
fi
