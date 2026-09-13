'use strict';

// Compiles a widget's source to the JavaScript a bundler can consume.
//
// The single definition of what each widget language means, shared by the
// esbuild plugins in bundleWidget.js and by the JavaScriptCore kernel the Swift
// daemon evaluates. Two copies would let one bundler learn a new CoffeeScript
// option or a different classic wrapper while the other kept the old contract.

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
