var test = require('tape');
var widgetify = require('../../src/widgetify');

test('transforming valid widgets', (t) => {
  var src = `
    var color = '#ff';
    var stuff = 1+2;
    color = color + 'f';
    ({
      foo: 14,
      style: 'color: ' + color,
      refreshFrequency: '2s'
    })
  `;

  const transformed = widgetify.transform(src, 'foo');
  const module = {};
  new Function('module', transformed)(module);

  t.ok(
    typeof module.exports === 'object',
    'it assigns the last object expression to module.exports'
  );
  t.equal(module.exports.id, 'foo', 'it adds the widget id');
  t.equal(
    module.exports.refreshFrequency, 2000,
    'it parses string refresh frequencies'
  );
  t.equal(
    module.exports.css, '#foo {\n  color: #fff;\n}\n',
    'it parses and scopes styles, including interpolated variables'
  );
  t.equal(module.exports.style, undefined, 'it cleans up the style property');

  t.end();
});

test('transforming a widget with a syntax error', (t) => {
  var src = `
    ({
      foo: 14,
      style: 'color: ' + color,
      refreshFrequency: '2s'
    })
  `;

  t.throws(
    () => widgetify.transform(src, 'foo'),
    /color is not defined/,
    'it throws, naming the undefined reference'
  );
  t.end();
});
