var test = require('tape');
var WebSocket = require('ws');

var server = new WebSocket.Server({ port: 8890 });
var sharedSocket = require('../../src/SharedSocket');
var url = 'ws://localhost:8890';

test('subscribing listeners and reconnecting', (t) => {
  var connections = 0;
  var messages = [];

  sharedSocket.onMessage((message) => {
    messages.push(message);
    if (messages.length < 2) return;
    t.deepEqual(messages, ['yay 1', 'yay 2'], 'it hears both connections');
    sharedSocket.close();
    server.close(() => t.end());
  });

  sharedSocket.open(url);

  // The first connection is dropped from the server's end; the socket has to
  // come back on its own to hear the second message.
  server.on('connection', (ws) => {
    connections += 1;
    ws.send('yay ' + connections);
    if (connections === 1) ws.terminate();
  });
});
