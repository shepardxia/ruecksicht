# Writing widgets

A widget is a `.jsx` module. Rendering is React 16; simple state is managed for
you, and for more than that you `dispatch` events into an `updateState` reducer.
Edits apply live and state survives the reload. A `.disabled` suffix keeps a
file from loading; subdirectories are not scanned, so shared code goes in one
and is reached by import.

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
cadence, so smooth motion does not mean re-running a shell command per frame.
`examples/two-clocks.widget` shows the split. A literal string `command` on a
readable `refreshFrequency` is run by the daemon once for every screen; a
function command runs in the page.

## The `uebersicht` module

```jsx
import {css, styled, run, request, React} from 'uebersicht';
```

`ruecksicht` resolves to the same module. `css` and `styled` are
[Emotion](https://emotion.sh) 10, `React` is the page's own, `request` is
[superagent](https://visionmedia.github.io/superagent/), and `run` executes a
shell command:

```jsx
run('echo hi').then((output) => dispatch({type: 'OUTPUT', output}));
```

Widgets receive clicks and other events only with "Enable interaction" on in
Preferences.

## Geolocation

The WebView's own geolocation does not work, so `navigator.geolocation` (also
`window.geolocation`) is replaced with `getCurrentPosition(callback)`,
`watchPosition(callback)` and `clearWatch(id)`. Options are not accepted, and
the position carries an `address` with `Street`, `City`, `ZIP`, `Country`,
`State` and `CountryCode`.

## Scripting

```applescript
tell application id "local.ruecksicht.Ruecksicht" to refresh
tell application id "local.ruecksicht.Ruecksicht" to reload widget id "my-widget"
tell application id "local.ruecksicht.Ruecksicht" to every widget
tell application id "local.ruecksicht.Ruecksicht" to set hidden of widget id "my-widget" to true
```

Widgets expose `id`, `hidden`, `showOnMainScreen` and `showOnAllScreens`.

## Classic widgets

CoffeeScript and object-literal widgets still load; see
[ClassicWidgets.md](ClassicWidgets.md).
