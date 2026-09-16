redux = require 'redux'
window.$ = require 'jquery'

reducer = require './src/reducer'
listenToRemote = require './src/listen'
sharedSocket = require './src/SharedSocket'
render = require './src/render'
actions = require './src/actions'
userCssLink = null
detectWidgetHover = require './src/detectWidgetHover'

# Widget bundles resolve their `uebersicht` import against this, so every
# widget shares the page's React and emotion instead of bundling its own.
window.__ubersicht = require './src/uebersicht'
window.__ubWidgets = {}


window.onload = ->
  path = window.location.pathname.split('/')
  screen =
    id: Number(path[1])
    layer: path[2]
  contentEl = document.getElementById('uebersicht')
  contentEl.innerHTML = ''
  userCssLink = Array.from(document.querySelectorAll('link'))
    .find((el) => el.href.match('userMain.css'))

  detectWidgetHover(contentEl);

  getState (err, initialState) ->
    bail err, 10000 if err?
    store = redux.createStore(reducer, initialState)
    Object.keys(initialState.widgets).forEach (id) ->
      fetchWidget(id)
        .then (widgetImpl) ->
          store.dispatch(actions.showWidget(id, widgetImpl))
          replayOutput(id)

    prevState = null
    store.subscribe ->
      nextState = store.getState()
      return if nextState == prevState
      render(store.getState(), screen, contentEl, store.dispatch)
      prevState = nextState

    listenToRemote (action) ->
      if action.type == 'WIDGET_WANTS_REFRESH'
        render.rendered[action.payload]?.instance?.forceRefresh()
      else if action.type == 'WIDGET_COMMAND_RAN'
        latestOutput[action.payload.id] = action.payload
        render.rendered[action.payload.id]?.instance?.receive(action.payload)
      else if action.type == 'WIDGET_ADDED'
        store.dispatch(action)
        return if action.payload.error
        fetchWidget(action.payload.id)
          .then (widgetImpl) ->
            store.dispatch(actions.showWidget(action.payload.id, widgetImpl))
            replayOutput(action.payload.id)
      else if action.type == 'MASTER_STYLE_CHANGED'
        reloadUserCSS()
      else
        store.dispatch(action)
    sharedSocket.open("ws://#{window.location.host}")
    render(initialState, screen, contentEl, store.dispatch)

# legacy
window.uebersicht =
  makeBgSlice: (canvas) ->
    console.warn 'makeBgSlice has been deprecated. Please use CSS \
      backdrop-filter instead: \
      https://developer.mozilla.org/en-US/docs/Web/CSS/backdrop-filter'

window.addEventListener 'contextmenu', (e) ->
  e.preventDefault()

# The server sends what it already knows the moment the socket opens, before
# any widget bundle has loaded; the result waits here for the widget.
latestOutput = {}

replayOutput = (id) ->
  payload = latestOutput[id]
  render.rendered[id]?.instance?.receive(payload) if payload

getState = (callback) ->
  $.get("/state/")
    .done((response) ->
      # jQuery parses the body itself when the response is served as JSON, and
      # hands back a string only when it is not.
      state = if typeof response is 'string' then JSON.parse(response) else response
      callback(null, state))
    .fail((err) -> callback(err, null))

fetchWidget = (id) -> new Promise (resolve, reject) ->
  scriptTag = document.createElement('SCRIPT')
  scriptTag.id = id
  scriptTag.src = '/widgets/' + id
  scriptTag.onload = ->
    document.head.removeChild(scriptTag)
    resolve(window.__ubWidgets[id])
  scriptTag.onerror = (err) ->
    document.head.removeChild(scriptTag)
    reject(err)
  document.head.appendChild(scriptTag)

reloadUserCSS = ->
  href = userCssLink.href.split('?')[0]
  userCssLink.href = "#{href}?#{new Date().getTime()}"

bail = (err, timeout = 0) ->
  console.log err if err?
  setTimeout ->
    window.location.reload(true)
  , timeout
