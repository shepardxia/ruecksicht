var http = require('http');
var URL = require('url');

module.exports = function httpPost(url, postData, callback) {
  var options = URL.parse(url);
  options.method = 'POST';
  options.headers = { 'Content-Length': postData.length };
  // Specs close a server and start another on the same port; a pooled
  // keep-alive socket would be reused against the dead one.
  options.agent = false;

  var req = http.request(options, (res) => {
    var buffer = '';
    res.setEncoding('utf8');
    res.on('data', (chunk) => buffer += chunk);
    res.on('end', () => callback(res, buffer));
  });

  req.write(postData);
  req.end();
};
