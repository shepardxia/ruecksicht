// Compiled to a standalone script and evaluated in JavaScriptCore, so the
// CoffeeScript and classic-widget transforms run without a Node runtime.

const coffee = require('coffee-script');
const widgetify = require('./widgetify');

globalThis.__ubTransform = function (source, id, isCoffee) {
  const js = isCoffee
    ? coffee.compile(source, {bare: true, header: false})
    : '({' + source + '})';
  return widgetify.transform(js, id);
};
