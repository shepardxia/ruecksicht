// nib's plugin, without its load-time package.json read.
const stylus = require('stylus');
function plugin() {
  return function (style) {
    style.include('/nib');
  };
}
module.exports = plugin;
module.exports.path = '/nib';
module.exports.version = '1.2.0';
