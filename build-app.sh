#!/bin/bash
# Builds Rücksicht.app without Xcode: clang for the sources and the SwiftPM
# daemon copied in as a resource. Every window and menu is built in code, so the
# app has no nibs.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Rücksicht.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

VERSION="1.0.0"
BUILD="1"
BUNDLE_ID="local.ruecksicht.Ruecksicht"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift build -c release --package-path "$ROOT/core" --product ubersichtd

# The executable's filename stays ASCII deliberately. macOS stores filenames
# decomposed, and codesign matches CFBundleExecutable against that form, so a
# precomposed "ü" written here leaves the main binary unrecognized and the
# bundle unsignable. Users read CFBundleName, never this.
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
cp "$ROOT/server/node_modules/@esbuild/darwin-$(uname -m | sed 's/x86_64/x64/')/bin/esbuild" \
  "$APP/Contents/MacOS/esbuild"
cp "$ROOT/core/.build/release/UebersichtCore_UebersichtCore.bundle/transform-kernel.js" \
  "$APP/Contents/Resources/transform-kernel.js"

# client.js is generated, not committed: a fresh clone has none, and an app
# without it loads a page that renders nothing at all.
[ -f "$ROOT/server/release/public/client.js" ] || (cd "$ROOT/server" && npm run build-client)

cp -R "$ROOT/server/public/." "$APP/Contents/Resources/"
cp "$ROOT"/Uebersicht/*.png "$ROOT"/Uebersicht/*.js "$APP/Contents/Resources/" 2>/dev/null || true
cp "$ROOT/Uebersicht/Uebersicht.sdef" "$APP/Contents/Resources/Rücksicht.sdef"

# Branding overrides the upstream artwork copied by the glob above, so it has to
# land after it. The status icon is a template image loaded by bare name.
cp "$ROOT/Uebersicht/branding/status-icon.png" "$APP/Contents/Resources/status-icon.png"
cp "$ROOT/Uebersicht/branding/status-icon@2x.png" "$APP/Contents/Resources/status-icon@2x.png"
cp "$ROOT/Uebersicht/branding/Ruecksicht.icns" "$APP/Contents/Resources/Rücksicht.icns"
cp "$ROOT/Uebersicht/branding/ruecksicht-logo.png" "$APP/Contents/Resources/ruecksicht-logo.png"
cp "$ROOT/Uebersicht/GettingStarted.jsx" "$APP/Contents/Resources/GettingStarted.jsx"

# A build that cannot bundle a widget, draw itself, or seed a first widget
# directory is not worth shipping. The daemon's three resolve from its own
# directory, so their absence only shows up once launched.
for required in MacOS/ubersichtd MacOS/esbuild Resources/transform-kernel.js \
                Resources/status-icon.png Resources/Rücksicht.icns \
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
plutil -replace CFBundleIconFile -string "Rücksicht" "$APP/Contents/Info.plist"
plutil -replace OSAScriptingDefinition -string "Rücksicht.sdef" "$APP/Contents/Info.plist"
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
