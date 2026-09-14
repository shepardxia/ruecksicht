'use strict';

// Compiles a widget's source to the JavaScript a bundler can consume.
//
// The single definition of what each widget language means. It reaches the
// daemon only as the JavaScriptCore kernel bundled by `npm run build-kernel`,
// so nothing here may touch a filesystem, a process or a module loader at call
// time.

const coffee = require('coffee-script/lib/coffee-script/coffee-script.js');
const widgetify = require('./widgetify');

module.exports = function transformWidget(source, id, isCoffee) {
  // A classic widget is a bare object literal; widgetify needs it as an
  // expression before it can rewrite it into a module export.
  const js = isCoffee
    ? coffee.compile(source, {bare: true, header: false})
    : '({' + source + '})';
  return widgetify.transform(js, id);
};
