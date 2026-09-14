'use strict';

const WebSocket = typeof window !== 'undefined'
  ? window.WebSocket
  : require('ws');

let ws = null;
const messageListeners = [];

function handleMessage(data) {
  messageListeners.forEach((f) => f(data));
}

function handleError(err) {
  console.error(err);
}

exports.open = function open(url) {
  ws = new WebSocket(url, ['ws'], {origin: 'Rücksicht'});

  // The page's WebSocket and the ws package attach listeners differently, and
  // the spec suite runs this module under Node.
  if (ws.on) {
    ws.on('message', handleMessage);
    ws.on('error', handleError);
  } else {
    ws.onmessage = (e) => handleMessage(e.data);
    ws.onerror = handleError;
  }
};

exports.close = function close() {
  ws.close();
  ws = null;
};

exports.onMessage = function onMessage(listener) {
  messageListeners.push(listener);
};
