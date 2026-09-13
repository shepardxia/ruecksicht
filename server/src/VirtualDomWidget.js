const css = require('emotion').css;
const RenderLoop = require('./RenderLoop');
const AnimationLoop = require('./AnimationLoop');
const Timer = require('./Timer');
const runShellCommand = require('./runShellCommand');
const ReactDom = require('react-dom');
const html = require('react').createElement;
const ErrorDetails = require('./ErrorDetails');
window.html = html;

const defaults = {
  id: 'widget',
  refreshFrequency: 1000,
  animationFrequency: AnimationLoop.DEFAULT_FREQUENCY,
  init: function init() {},
  render: function render(props) {
    return html('div', null, props.error ? String(props.error) : props.output);
  },
  updateState: function updateState(event) {
    return {error: event.error, output: event.output};
  },
  initialState: {output: ''},
};

// One clock per page, shared by every animating widget on it.
const animationLoop = AnimationLoop();

module.exports = function VirtualDomWidget(widgetObject) {
  const api = {};
  let implementation;
  let contentEl;
  let commandLoop;
  let renderLoop;
  let currentError;

  function init(widget) {
    currentError = widget.error ? JSON.parse(widget.error) : undefined;
    implementation = Object.create(defaults);
    Object.assign(implementation, widget.implementation || {}, {id: widget.id});
    return api;
  }

  function start() {
    if (currentError) {
      renderErrorDetails(currentError);
      return;
    }
    if (renderLoop) {
      renderLoop.update(renderLoop.state); // force redraw
    } else {
      renderLoop = RenderLoop(implementation.initialState, render);
    }
    run();
  }

  // `refreshFrequency` is the data cadence; motion runs on its own clock so a
  // widget that wants smooth movement no longer has to re-run its command at
  // frame rate to get it.
  function startAnimating() {
    if (typeof implementation.animate !== 'function') return;
    animationLoop.add(
      implementation.id,
      (dtMs) => {
        const next = implementation.animate(renderLoop.state, dtMs);
        if (next !== undefined) renderLoop.update(next);
        return next;
      },
      implementation.animationFrequency,
      handleError,
    );
  }

  function run() {
    implementation.init(dispatch);
    startAnimating();
    if (!implementation.command) return;
    // The server runs literal commands once for every screen and pushes the
    // result; running the same command here again would double the work.
    if (widgetObject.serverDriven) return;
    commandLoop = Timer()
      .start()
      .map((done) => {
        execWidgetCommand()
          .then(commandCompleted)
          .catch(commandErrored)
          .then(() => done(implementation.refreshFrequency));
      });
  }

  function commandCompleted(output) {
    dispatch({type: 'UB/COMMAND_RAN', output});
  }

  function commandErrored(error) {
    dispatch({type: 'UB/COMMAND_RAN', error});
  }

  const runCommandFunction = (command) => {
    try {
      return command.apply(implementation, [dispatch]);
    } catch (err) {
      handleError(err);
    }
  };

  function execWidgetCommand() {
    const {command} = implementation;
    if (typeof command === 'function')
      return Promise.resolve(runCommandFunction(command));
    else if (typeof command === 'string') return runShellCommand(command);
    else return Promise.resolve();
  }

  function dispatch(event) {
    try {
      const nextState = implementation.updateState(event, renderLoop.state);
      renderLoop.update(nextState);
      // New data revives an animation that had settled and parked itself.
      animationLoop.wake(implementation.id);
    } catch (err) {
      handleError(err);
    }
  }

  function fetchErrorDetails(err) {
    return fetch(
      `/widgets/${widgetObject.id}?line=${err.line}&column=${err.column}`,
    ).then((res) => res.json());
  }

  function render(state) {
    try {
      ReactDom.render(implementation.render(state, dispatch), contentEl);
    } catch (err) {
      handleError(err);
    }
  }

  function handleError(err) {
    currentError = err;
    commandLoop && commandLoop.stop();
    fetchErrorDetails(err).then((details) => {
      if (err !== currentError) return;
      renderErrorDetails(Object.assign({message: err.message}, details));
    });
  }

  function renderErrorDetails(details) {
    ReactDom.render(html(ErrorDetails, details), contentEl);
  }

  api.create = function create() {
    contentEl = document.createElement('div');
    contentEl.id = implementation.id;
    contentEl.classList.add('widget');
    if (implementation.className) {
      contentEl.classList.add(css(implementation.className));
    }
    document.body.appendChild(contentEl);
    start();
    return contentEl;
  };

  api.destroy = function destroy() {
    animationLoop.remove(implementation.id);
    commandLoop && commandLoop.stop();
    if (contentEl && contentEl.parentNode) {
      contentEl.parentNode.removeChild(contentEl);
    }
    renderLoop = null;
    contentEl = null;
    currentError = null;
  };

  api.update = function update(newImplementation) {
    animationLoop.remove(implementation.id);
    commandLoop && commandLoop.stop();
    contentEl.classList.remove(css(implementation.className));
    init(newImplementation);
    if (implementation.className) {
      contentEl.classList.add(css(implementation.className));
    }
    start();
  };

  api.forceRefresh = function forceRefresh() {
    commandLoop && commandLoop.forceTick();
  };

  api.receive = function receive(result) {
    dispatch({type: 'UB/COMMAND_RAN', output: result.output, error: result.error});
  };

  return init(widgetObject);
};
