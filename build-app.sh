#!/bin/bash
# Builds Übersicht.app without Xcode: clang for the sources, ibtool for the
# nibs, and the SwiftPM daemon copied in as a resource.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Übersicht.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

swift build -c release --package-path "$ROOT/core" --product ubersichtd

clang -fobjc-arc -fmodules -mmacosx-version-min=13.0 -isysroot "$SDK" \
  -I "$ROOT/Uebersicht" -I "$ROOT/Pods/SocketRocket" -I "$ROOT/Pods/SocketRocket/SocketRocket" \
  -F "$ROOT/Pods/Sparkle" \
  -framework Cocoa -framework WebKit -framework CoreLocation \
  -framework IOKit -framework Security -framework SystemConfiguration \
  -framework Sparkle -rpath @executable_path/../Frameworks \
  -Wno-deprecated-declarations -Wno-nullability-completeness \
  -include "$ROOT/Uebersicht/Uebersicht-Prefix.pch" \
  $(ls "$ROOT"/Uebersicht/*.m | grep -v UBPreferencesController.m) \
  "$ROOT/Pods/SocketRocket/SocketRocket/SRWebSocket.m" \
  -o "$APP/Contents/MacOS/Übersicht"

cp -R "$ROOT/Pods/Sparkle/Sparkle.framework" "$APP/Contents/Frameworks/"
cp "$ROOT/core/.build/release/ubersichtd" "$APP/Contents/Resources/"

# The daemon resolves both of these relative to its own location, so they must
# sit beside it: the SwiftPM resource bundle holds the transform kernel, and
# esbuild is the bundler itself.
cp -R "$ROOT/core/.build/release/UebersichtCore_UebersichtCore.bundle" "$APP/Contents/Resources/"
cp "$ROOT/server/node_modules/@esbuild/darwin-$(uname -m | sed 's/x86_64/x64/')/bin/esbuild" \
  "$APP/Contents/Resources/esbuild"

cp -R "$ROOT/server/public/." "$APP/Contents/Resources/"
cp "$ROOT"/Uebersicht/*.png "$ROOT"/Uebersicht/*.js "$APP/Contents/Resources/" 2>/dev/null || true
cp "$ROOT/Uebersicht/Uebersicht.sdef" "$APP/Contents/Resources/"

# ibtool needs Xcode's IDE plugins, which are broken on this machine. Where a
# released build is installed, its nibs come from these same xibs.
INSTALLED="/Applications/Übersicht.app/Contents/Resources"
if ibtool --compile "$APP/Contents/Resources/MainMenu.nib" \
      "$ROOT/Uebersicht/Base.lproj/MainMenu.xib" 2>/dev/null; then
  ibtool --compile "$APP/Contents/Resources/UBPreferencesController.nib" \
      "$ROOT/Uebersicht/UBPreferencesController.xib"
elif [ -d "$INSTALLED" ]; then
  echo "ibtool unavailable; taking compiled nibs from $INSTALLED"
  mkdir -p "$APP/Contents/Resources/Base.lproj"
  cp -R "$INSTALLED"/Base.lproj/*.nib "$APP/Contents/Resources/Base.lproj/"
  cp -R "$INSTALLED"/*.nib "$APP/Contents/Resources/"
else
  echo "no way to produce nibs: ibtool is unavailable and no installed build to copy from" >&2
  exit 1
fi

# An app whose menu never appears is not a build worth shipping.
[ -f "$APP/Contents/Resources/Base.lproj/MainMenu.nib" ] || {
  echo "MainMenu.nib missing from the bundle" >&2; exit 1
}

# Nor is one whose daemon cannot bundle a widget. These resolve from the
# daemon's own directory, so their absence only shows up once launched.
for required in ubersichtd esbuild UebersichtCore_UebersichtCore.bundle; do
  [ -e "$APP/Contents/Resources/$required" ] || {
    echo "$required missing from the bundle" >&2; exit 1
  }
done

cp "$ROOT/Uebersicht/Uebersicht-Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "Übersicht" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "tracesOf.Uebersicht" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "Übersicht" "$APP/Contents/Info.plist"
plutil -remove SUFeedURL "$APP/Contents/Info.plist" 2>/dev/null || true
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signing is best effort: it is not required to run a local build, and
# codesign itself is broken on machines with a partial Xcode install.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "note: ad-hoc signing unavailable"
echo "built $APP"
