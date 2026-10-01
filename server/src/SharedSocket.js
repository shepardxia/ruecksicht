'use strict';

const WebSocket = typeof window !== 'undefined'
  ? window.WebSocket
  : require('ws');

const RECONNECT_DELAY = 1000;

let ws = null;
let reconnecting = null;
const messageListeners = [];

function handleMessage(data) {
  messageListeners.forEach((f) => f(data));
}

function handleError(err) {
  console.error(err);
}

exports.open = function open(url) {
  const socket = new WebSocket(url, ['ws'], {origin: 'Rücksicht'});
  ws = socket;

  // Server-driven widgets only change when a result is pushed, so a socket
  // that dropped for good would leave them on their last one. A socket closed
  // through `close` is no longer `ws` and stays closed.
  const handleClose = () => {
    if (ws !== socket) return;
    reconnecting = setTimeout(() => open(url), RECONNECT_DELAY);
  };

  // The page's WebSocket and the ws package attach listeners differently, and
  // the spec suite runs this module under Node.
  if (socket.on) {
    socket.on('message', handleMessage);
    socket.on('error', handleError);
    socket.on('close', handleClose);
  } else {
    socket.onmessage = (e) => handleMessage(e.data);
    socket.onerror = handleError;
    socket.onclose = handleClose;
  }
};

exports.close = function close() {
  clearTimeout(reconnecting);
  const socket = ws;
  ws = null;
  socket.close();
};

exports.onMessage = function onMessage(listener) {
  messageListeners.push(listener);
};
