'use strict';

const ws = require('./SharedSocket');
const listeners = [];
const pending = [];

ws.onMessage(function handleMessage(data) {
  let message;
  try { message = JSON.parse(data); } catch (e) { null; }
  if (!message) return;

  // The socket is opened first thing on load and the server answers with
  // everything it already knows, well before the page has finished booting and
  // subscribed. Held here, that first result reaches the widget; dropped, the
  // widget shows its placeholder until the next tick.
  if (listeners.length === 0) {
    pending.push(message);
    return;
  }

  listeners.forEach((f) => f(message));
});

module.exports = function listen(callback) {
  listeners.push(callback);
  while (pending.length) callback(pending.shift());
};
