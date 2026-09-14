# Rücksicht

*Keep an eye on what's happening on your machine.*

Rücksicht is a macOS desktop widget host: small JavaScript modules rendered by
WebKit and pinned to the desktop, behind your windows. It is a fork of
[Übersicht](http://tracesof.net/uebersicht) by Felix Hageloh, with the bundled
Node server replaced by a Swift daemon (`ubersichtd`) that serves the widget
pages, bundles widgets with [esbuild](https://esbuild.github.io) and runs their
shell commands in persistent shells. No Node runtime ships in the app.

Widgets written for Übersicht run here unmodified.

## Building and installing

Requires the Xcode Command Line Tools (clang, swift, codesign) and Node for the
build toolchain. Xcode itself is not used: the app has no nibs and no Xcode
project, and every window and menu is built in code.

```sh
cd server && npm install   # supplies the esbuild binary and the bundler
npm run build-client       # server/release/public/client.js is not checked in
cd .. && ./build-app.sh    # writes build/Rücksicht.app
./install.sh               # copies it to /Applications and adds a login item
```

`./install.sh --replace-uebersicht` additionally removes an installed Übersicht,
its login item and its preferences. Widgets are never touched.

`npm run build-kernel` regenerates `core/Sources/UebersichtCore/Resources/transform-kernel.js`,
which hosts the CoffeeScript and classic-widget compilers. It is checked in, so
this is only needed when its sources change.

`node server/bin/ubdoctor [widget-dir] [--json]` reports on a widget directory --
what parses, what would break -- without launching the app.

## Writing widgets

Widgets live in `~/Library/Application Support/Rücksicht/widgets`. A widget is a
`<name>.widget` directory there, and every `.jsx`, `.js` or `.coffee` file
directly inside it is loaded as a widget of its own. Subdirectories are not
scanned, so shared code and dependencies belong in one (`lib/`, `src/`,
`node_modules/`) and are reached by import. A `.disabled` suffix keeps a file
from loading. Edits are applied live, and widget state survives a reload, so you
can code against a running widget. CoffeeScript widgets are still supported; see
[the classic documentation](ClassicWidgets.md).

Rendering is React (16) with JSX. Simple state is managed for you; for more than
that you `dispatch` events into an `updateState` reducer.

A widget is a module that exports any of:

| export | type | meaning |
| --- | --- | --- |
| `command` | string, or `(dispatch) => …` | shell command to run, or a function that dispatches events itself |
| `refreshFrequency` | number | delay in ms between command runs, 1000 by default |
| `initialState` | any | state before the first event arrives |
| `updateState` | `(event, previous) => next` | reducer over dispatched events and command output |
| `init` | `(dispatch) => …` | called once on load, for setup such as opening a socket |
| `render` | `(state, dispatch) => JSX` | the widget's markup |
| `className` | string | CSS for the widget's root node, including its position |
| `animate` | `(state, dtMs) => next \| undefined` | one step of motion; returning `undefined` parks the shared loop |
| `animationFrequency` | number | steps per second while `animate` keeps returning state |

`refreshFrequency` is the data cadence and `animationFrequency` the motion
cadence: smooth motion does not require re-running the shell command per frame.
`examples/two-clocks.widget/index.jsx` is the reference for that split.

### The `uebersicht` module

```jsx
import {css, styled, run, request, React} from 'uebersicht';
```

`ruecksicht` resolves to the same module; the import name is part of the widget
format, so both work. It provides [Emotion](https://emotion.sh) 10 (`css`,
`styled`), the page's own `React` -- imported rather than duplicated per widget
-- `request` ([superagent](https://visionmedia.github.io/superagent/)), and:

```jsx
run('echo "new output"').then((output) => dispatch({type: 'OUTPUT', output}));
```

`run` returns a promise that resolves with the command's stdout and rejects on
error. Widgets only receive clicks and other events when "Enable interaction" is
on in Preferences.

### Geolocation

The WebView's own HTML5 geolocation is not functional, so the app replaces
`getCurrentPosition(callback)`, `watchPosition(callback)` and
`clearWatch(watchId)` on `navigator.geolocation`, and exposes the same object as
`window.geolocation`. Options are not accepted -- accuracy is always highest --
and the position carries an extra `address` property with `Street`, `City`,
`ZIP`, `Country`, `State` and `CountryCode`.

## Scripting

```applescript
tell application id "local.ruecksicht.Ruecksicht" to refresh
tell application id "local.ruecksicht.Ruecksicht" to reload widget id "my-widget"
tell application id "local.ruecksicht.Ruecksicht" to every widget
tell application id "local.ruecksicht.Ruecksicht" to set hidden of widget id "my-widget" to true
```

Widgets expose `id`, `hidden`, `showOnMainScreen` and `showOnAllScreens`. Scripts
address the app by id because typing the umlaut is awkward.

## Legal

The source for Rücksicht is released under the GNU General Public License as
published by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Übersicht © 2019 Felix Hageloh.
