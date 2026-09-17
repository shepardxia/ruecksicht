# Rücksicht

Desktop widgets for macOS: small JavaScript modules rendered by WebKit behind
your windows. A fork of [Übersicht](https://github.com/felixhageloh/uebersicht)
with the Node server replaced by a Swift daemon. Übersicht widgets run unmodified.

## Install

```sh
brew tap shepardxia/ruecksicht https://github.com/shepardxia/ruecksicht
brew install ruecksicht
brew services start ruecksicht
```

## Widgets

```sh
rk add ~/code/my-widget                      # a directory is a widget
rk add https://github.com/you/some-widget    # cloned, then the same
rk list
rk update                                    # git pull the clones
rk remove some-widget [--purge]
rk log [-f]
rk restart
```

Every `.jsx`, `.js` or `.coffee` file directly inside a widget directory is a
widget; its files are served under the directory's name and its command runs
inside it. `~/Library/Application Support/Rücksicht/widgets` is always
registered, and `<name>.widget` folders in it work as they did in Übersicht.
Edits apply live.

## Writing widgets

```jsx
import {css, styled, run, request, React} from 'uebersicht';
```

| export | type | meaning |
| --- | --- | --- |
| `command` | string, or `(dispatch) => …` | shell command to run, or a function that dispatches itself |
| `refreshFrequency` | number | ms between runs, 1000 by default |
| `initialState` | any | state before the first event |
| `updateState` | `(event, previous) => next` | reducer over events and command output |
| `init` | `(dispatch) => …` | called once on load |
| `render` | `(state, dispatch) => JSX` | the markup |
| `className` | string | CSS for the root node, including its position |
| `animate` | `(state, dtMs) => next \| undefined` | one step of motion; `undefined` parks the loop |
| `animationFrequency` | number | steps per second |

`refreshFrequency` is the data cadence and `animationFrequency` the motion
cadence; see `examples/two-clocks.widget`. Clicks reach widgets only with
"Enable interaction" on. CoffeeScript widgets: [ClassicWidgets.md](ClassicWidgets.md).

## Scripting

```applescript
tell application id "local.ruecksicht.Ruecksicht" to refresh
tell application id "local.ruecksicht.Ruecksicht" to set hidden of widget id "my-widget" to true
```

## Building

Xcode Command Line Tools and `esbuild`. `cd server && npm install && npm run
build-client`, then `./build-app.sh` and `./install.sh`. `./release.sh --publish`
cuts a release and repoints the formula.

## Legal

GPL-3.0-or-later. Übersicht © 2019 [Felix Hageloh](https://github.com/felixhageloh/uebersicht).
