#!/bin/bash
# Installs a built Rücksicht.app into /Applications and makes it the app that
# starts at login.
#
#   --app PATH             install this bundle instead of the one in ./build
#   --replace-uebersicht   also remove an installed Übersicht, its login item
#                          and its preferences; widgets are never touched
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${BUILD_DIR:-$ROOT/build}/Rücksicht.app"
REPLACE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --replace-uebersicht) REPLACE=yes; shift ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

DEST="/Applications/Rücksicht.app"
BUNDLE_ID="local.ruecksicht.Ruecksicht"
OLD_APP="/Applications/Übersicht.app"
OLD_ID="tracesOf.Uebersicht"

[ -d "$APP" ] || { echo "no build at $APP -- run ./build-app.sh first" >&2; exit 1; }
codesign --verify --strict "$APP" || { echo "build is not validly signed" >&2; exit 1; }

quit_app() {
    osascript -e "tell application id \"$2\" to quit" 2>/dev/null || true
    pkill -f "$1/Contents/MacOS/" 2>/dev/null || true
}

quit_app "$DEST" "$BUNDLE_ID"
[ -d "$OLD_APP" ] && quit_app "$OLD_APP" "$OLD_ID"

rm -rf "$DEST"
cp -R "$APP" "$DEST"
codesign --verify --strict "$DEST"

# Carry over how the widgets are layered, which is the only preference state
# that is about the desktop rather than about the old app's updater.
if [ -f "$HOME/Library/Preferences/$OLD_ID.plist" ]; then
    for key in appearance interactionMode; do
        if value=$(defaults read "$OLD_ID" "$key" 2>/dev/null); then
            defaults write "$BUNDLE_ID" "$key" -string "$value"
        fi
    done
    # `defaults read` prints a boolean as 1/0, which `defaults write -bool`
    # rejects.
    if value=$(defaults read "$OLD_ID" widgetsOnTop 2>/dev/null); then
        [ "$value" = "1" ] && value=true || value=false
        defaults write "$BUNDLE_ID" widgetsOnTop -bool "$value"
    fi
    if value=$(defaults read "$OLD_ID" windowLevel 2>/dev/null); then
        defaults write "$BUNDLE_ID" windowLevel -int "$value"
    fi
fi

osascript -e 'tell application "System Events" to delete login item "Rücksicht"' 2>/dev/null || true
osascript -e "tell application \"System Events\" to make login item at end \
    with properties {path:\"$DEST\", hidden:false}" >/dev/null

if [ -n "$REPLACE" ]; then
    osascript -e 'tell application "System Events" to delete login item "Übersicht"' 2>/dev/null || true
    rm -rf "$OLD_APP"
    rm -f "$HOME/Library/Preferences/$OLD_ID.plist"
    rm -rf "$HOME/Library/Caches/$OLD_ID"
    rm -rf "$HOME/Library/Saved Application State/$OLD_ID.savedState"
    defaults read "$OLD_ID" >/dev/null 2>&1 && defaults delete "$OLD_ID" >/dev/null 2>&1 || true
    echo "removed Übersicht"
fi

echo "installed $DEST"
