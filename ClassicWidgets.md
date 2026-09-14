# Classic widgets

The classic widget format: a plain JavaScript or CoffeeScript object rather than
a module of exports. Rücksicht still compiles it, so widgets written for older
Übersicht releases keep working. New widgets are better written in the `.jsx`
format described in [README.md](README.md).

## Writing Widgets

A classic widget is a single `.js` or `.coffee` file directly inside a
`<name>.widget` directory under `~/Library/Application Support/Rücksicht/widgets`.
Subdirectories are not scanned, so shared code and node modules belong in one
(`lib/`, `src/`, `node_modules/`) and are reached with [NodeJS' module
syntax](https://www.sitepoint.com/understanding-module-exports-exports-node-js/).
File changes are picked up live.

This documentation uses [CoffeeScript](http://coffeescript.org) syntax. Plain JS
widgets work as well, but have no CommonJS support; CoffeeScript's back-tick
<tt>`</tt> operator lets you write the relevant parts in JavaScript.

The following properties and methods are currently supported:


### command

A **string** containing the shell command to be executed, or
a **function(callback)** which eventually calls callback with some data.
For example:

```coffeescript
command: "echo Hello World"
```

Watch out for quotes inside commands. Often they need to properly escaped, like:

```coffeescript
command: "ps axo \"rss,pid,ucomm\" | sort -nr | head -n3"
```

Example using a command function:

```coffeescript
command: (callback) ->
  # example function that fetches data from a server
  fetchData 'some/url', (error, data) ->
    callback(error, data)
```

The first and only argument passed to a command function is a callback, which must be called to continue running the widget. It follows the standard NodeJS [error-first callback pattern](http://fredkschott.com/post/2014/03/understanding-error-first-callbacks-in-node-js/).


### refreshFrequency

An **integer** specifying how often the above command is executed. It defines the delay in milliseconds between consecutive commands executions. Example:

```coffeescript
refreshFrequency: 10000
```

You can also specify `refreshFrequency` as a string, like '2 days', '1d', '10h', '2.5 hrs', '2h', '1m', or '5s'.

```coffeescript
refreshFrequency: '10s'  # equates to 10000
```

The default is 1000 (1s). If set to `false` the widget won't refresh automatically.

### style

A **string** defining the css style of this widget, which is also used to control the position. In order to allow for easy scoping of CSS rules, styles are written using the [Stylus](http://learnboost.github.io/stylus/) preprocessor. Example:

```coffeescript
style: """
  top:  0
  left: 0
  color: #fff

  .some-class
    box-shadow: 0 0 2px rgba(#000, 0.1)
"""
```

For convenience, the [nib library](https://tj.github.io/nib/) for Stylus is included, so mixins for CSS3 are available.

Note that widgets are positioned absolute in relation to the screen (minus the menu bar), so a widget with `top: 0` and `left: 0` will be positioned in the top left corner of the screen, just below the menu bar.


### render : output

A **function** returning a HTML string to render this widget. It gets the output of `command` passed in as a string. For example, a widget with:

```coffeescript
command: "echo Hello World!"

render: (output) -> """
  <h1>#{output}</h1>
"""
```

would render as **Hello World!**. Usually, your `output` will be something more complicated, for example a JSON string, so you will have to parse it first.

The default implementation of render just returns `output`.

### afterRender : domEl

A **function** that gets called, as the name suggests, after `render` with a reference to our newly rendered DOM element. It can be used to do one time setups that you wouldn't want to do on every update.


### update : output, domEl

A **function** implementing update behavior of this widget. If specified, `render` will be called once when the widget is first initialized. Afterwards, update will be called for every refresh cycle. If no update method is provided, `render` will be called instead.

Since `render` will simply replace the inner HTML of a widget every time, you can use render to do a partial update of your widgets, kick off animations etc. For example, if the output of your command returns a percentage, you could do something like:

```coffeescript
# we don't care about output here
render: (_) -> """
  <div class='bar'></div>
"""

update: (output, domEl) ->
  $(domEl).find('.bar').css height: output+'%'
```

This will set the height of .bar every time this widget refreshes. As you can see, jQuery is available.

## Widget Internals

For writing more advanced widgets you might not want to rely on the standard 'run command, then redraw' cycle and instead manage some of the widget internals yourself. There are a few methods you can use from within `render`, `afterRender` and `update`

### @stop()

Stop the widget from updating if a `refreshFrequency` is set. The widget won't update until `@start` is called.

### @start()

Start updating a previously stopped widget again. Does nothing if `refreshFrequency` is set to `false`.

### @refresh()

Runs the command and redraws the widget as it normally would as part of a refresh cycle. If no command is set, the widget will only redraw.

### @run(command, callback)

Runs a shell command and calls callback with the result. Command is a string containing the shell command, just like the `command` property of a widget. Callback is called with err (if any) and stdout, in standard node fashion.

## Geolocation API

The same as for `.jsx` widgets; see [README.md](README.md).

## Hosted Functionality

A global object called `uebersicht` exists which exposes extra functionality that is typically not available in a browser. At the moment it is very limited:


### uebersicht.makeBgSlice(canvas)

Has been deprecated as of version 0.8 in favor of -webkit-backdrop-filter. It should be available on all systems that have Safari 9+ installed. https://developer.mozilla.org/en-US/docs/Web/CSS/backdrop-filter

## Scripting Support

AppleScript support is described in [README.md](README.md).

# Legal

The source for Übersicht is released under the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

© 2016 Felix Hageloh
