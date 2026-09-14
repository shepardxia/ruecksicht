#!/bin/bash
# Builds Rücksicht.app without Xcode: clang for the app sources and SwiftPM for
# the daemon. Every window and menu is built in code, so the app has no nibs.
#
# BUILD_DIR puts the bundle somewhere other than ./build, ESBUILD names the
# esbuild binary to embed, and CODESIGN_IDENTITY signs with a real certificate
# instead of ad-hoc.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${BUILD_DIR:-$ROOT/build}/Rücksicht.app"

VERSION="$(cat "$ROOT/VERSION")"
BUILD="1"
BUNDLE_ID="local.ruecksicht.Ruecksicht"

for tool in xcrun clang swift codesign plutil; do
  command -v "$tool" >/dev/null || {
    echo "$tool not found -- install the Xcode Command Line Tools" >&2; exit 1
  }
done
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# esbuild is one static binary, embedded in the bundle and run by the daemon. A
# checkout with the npm toolchain installed has one; a build from a release
# tarball takes the one on PATH.
ESBUILD="${ESBUILD:-$ROOT/server/node_modules/@esbuild/darwin-$(uname -m | sed 's/x86_64/x64/')/bin/esbuild}"
[ -x "$ESBUILD" ] || ESBUILD="$(command -v esbuild || true)"
[ -x "$ESBUILD" ] || {
  echo "no esbuild -- brew install esbuild, or npm install in server/" >&2; exit 1
}

# client.js is generated, not committed: a release tarball carries one, a fresh
# clone does not, and an app without it loads a page that renders nothing.
if [ ! -f "$ROOT/server/release/public/client.js" ]; then
  command -v npm >/dev/null || {
    echo "no client.js in server/release/public and no npm to build one" >&2; exit 1
  }
  [ -d "$ROOT/server/node_modules" ] || (cd "$ROOT/server" && npm install)
  (cd "$ROOT/server" && npm run build-client)
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --disable-sandbox: SwiftPM sandboxes its own manifest compile, and that
# sandbox cannot nest inside another one. Under a build that is already
# sandboxed -- Homebrew's, for one -- the manifest fails to compile at all.
swift build -c release --disable-sandbox --package-path "$ROOT/core" --product ubersichtd

# Every filename inside the bundle stays ASCII deliberately. macOS stores
# filenames decomposed while this script writes them precomposed, and the
# signature is sealed over the name: codesign will not recognize a main binary
# spelled the other way, and an archiver that renormalizes on the way through
# invalidates the seal on any resource that is. Users read CFBundleName.
clang -fobjc-arc -fmodules -mmacosx-version-min=13.0 -isysroot "$SDK" \
  -I "$ROOT/Uebersicht" -I "$ROOT/Pods/SocketRocket" -I "$ROOT/Pods/SocketRocket/SocketRocket" \
  -framework Cocoa -framework WebKit -framework CoreLocation \
  -framework IOKit -framework Security -framework SystemConfiguration \
  -Wno-deprecated-declarations -Wno-nullability-completeness \
  -include "$ROOT/Uebersicht/Uebersicht-Prefix.pch" \
  $(ls "$ROOT"/Uebersicht/*.m | grep -v UBPreferencesController.m) \
  "$ROOT/Pods/SocketRocket/SocketRocket/SRWebSocket.m" \
  -o "$APP/Contents/MacOS/Ruecksicht"

# The daemon and its tools live beside the main executable, not in Resources:
# nested code sealed as a resource invalidates the enclosing signature. The
# daemon resolves the other two relative to its own location -- esbuild is the
# bundler, and the kernel hosts the CoffeeScript and classic-widget compilers.
cp "$ROOT/core/.build/release/ubersichtd" "$APP/Contents/MacOS/"
cp "$ESBUILD" "$APP/Contents/MacOS/esbuild"
cp "$ROOT/core/Sources/UebersichtCore/Resources/transform-kernel.js" \
  "$APP/Contents/Resources/transform-kernel.js"

cp -R "$ROOT/server/public/." "$APP/Contents/Resources/"
cp "$ROOT"/Uebersicht/*.png "$ROOT"/Uebersicht/*.js "$APP/Contents/Resources/" 2>/dev/null || true
cp "$ROOT/Uebersicht/Uebersicht.sdef" "$APP/Contents/Resources/Ruecksicht.sdef"

# Branding overrides the upstream artwork copied by the glob above, so it has to
# land after it. The status icon is a template image loaded by bare name.
cp "$ROOT/Uebersicht/branding/status-icon.png" "$APP/Contents/Resources/status-icon.png"
cp "$ROOT/Uebersicht/branding/status-icon@2x.png" "$APP/Contents/Resources/status-icon@2x.png"
cp "$ROOT/Uebersicht/branding/Ruecksicht.icns" "$APP/Contents/Resources/Ruecksicht.icns"
cp "$ROOT/Uebersicht/branding/ruecksicht-logo.png" "$APP/Contents/Resources/ruecksicht-logo.png"
cp "$ROOT/Uebersicht/GettingStarted.jsx" "$APP/Contents/Resources/GettingStarted.jsx"

# A build that cannot bundle a widget, draw itself, or seed a first widget
# directory is not worth shipping. The daemon's three resolve from its own
# directory, so their absence only shows up once launched.
for required in MacOS/ubersichtd MacOS/esbuild Resources/transform-kernel.js \
                Resources/status-icon.png Resources/Ruecksicht.icns \
                Resources/ruecksicht-logo.png Resources/GettingStarted.jsx \
                Resources/client.js Resources/index.html; do
  [ -e "$APP/Contents/$required" ] || {
    echo "$required missing from the bundle" >&2; exit 1
  }
done

cp "$ROOT/Uebersicht/Uebersicht-Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "Ruecksicht" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "Rücksicht" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
plutil -replace CFBundleIconFile -string "Ruecksicht" "$APP/Contents/Info.plist"
plutil -replace OSAScriptingDefinition -string "Ruecksicht.sdef" "$APP/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "13.0" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Inside out, and never --deep: the SwiftPM resource bundle carries no recognized
# bundle format, and --deep crashes recursing into it rather than skipping it. It
# holds no code, so being sealed as an ordinary resource of the app is correct.
#
# Under the hardened runtime JavaScriptCore cannot allocate executable memory
# without the entitlement, so the daemon that hosts the transform kernel is
# signed with it. esbuild is a Go binary and needs only the runtime flag.
SIGN="${CODESIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT/Uebersicht/Ruecksicht.entitlements"

codesign --force --options runtime --sign "$SIGN" "$APP/Contents/MacOS/esbuild"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN" \
  "$APP/Contents/MacOS/ubersichtd"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN" "$APP"
codesign --verify --strict "$APP"

# A build whose kernel cannot JIT would fail only on the first CoffeeScript or
# classic widget, long after this script exits.
codesign -d --entitlements - "$APP" 2>/dev/null \
  | grep -q 'allow-unsigned-executable-memory' || {
    echo "the JavaScriptCore entitlement did not make it onto the bundle" >&2; exit 1
  }

echo "built $APP ($VERSION build $BUILD)"
