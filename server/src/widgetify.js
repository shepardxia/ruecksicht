var esprima = require('esprima');
var escodegen = require('escodegen');
var stylus = require('stylus');
var nib = require('nib');
var ms = require('ms');

function addExports(node) {
  var widgetObjectExp = node.expression;

  node.expression = {
    type: 'AssignmentExpression',
    operator: '=',
    left: { type: 'Identifier', name: 'module.exports' },
    right: widgetObjectExp,
  };
}

function addId(widgetObjectExp, widetId) {
  var idProperty = {
    type: 'Property',
    key: { type: 'Identifier', name: 'id' },
    value: { type: 'Literal', value: widetId },
    computed: false,
  };

  widgetObjectExp.properties.push(idProperty);
}

function flattenStyle(styleProp, tree) {
  var preface = {
    type: 'Program',
    body: tree.body.slice(0, -1),
  };

  preface.body.push({
    type: 'ExpressionStatement',
    expression: styleProp.value,
  });

  return eval(escodegen.generate(preface));
}

function parseStyle(styleProp, widetId, tree) {
  var styleString;

  if (styleProp.value.type === 'Literal') {
    styleString = styleProp.value.value;
  } else {
    styleString = flattenStyle(styleProp, tree);
  }

  if (typeof styleString !== 'string') {
    return;
  }

  var scopedStyle = '#' + widetId
    + '\n  '
    + styleString.replace(/\n/g, '\n  ');

  // nib's mixin library resolves its imports from disk. Where there is no
  // filesystem to resolve them against, plain stylus still compiles everything
  // that does not use a nib mixin, which is the overwhelming majority.
  var css;
  try {
    css = stylus(scopedStyle).import('nib').use(nib()).render();
  } catch (e) {
    css = stylus(scopedStyle).render();
  }

  styleProp.key.name = 'css';
  styleProp.value.type = 'Literal';
  styleProp.value.value = css;
}

function parseRefreshFrequency(prop) {
  if (typeof prop.value.value === 'string') {
    prop.value.value = ms(prop.value.value);
  }
}

function parseWidgetProperty(prop, widgetId, tree) {
  switch (prop.key.name) {
    case 'style': parseStyle(prop, widgetId, tree); break;
    case 'refreshFrequency': parseRefreshFrequency(prop); break;
  }
}

function modifyAST(tree, widgetId) {
  var widgetObjectExp = getWidgetObjectExpression(tree);

  if (widgetObjectExp) {
    widgetObjectExp.properties.map(function(prop) {
      parseWidgetProperty(prop, widgetId, tree);
    });
    addId(widgetObjectExp, widgetId);
    addExports(tree.body[tree.body.length - 1]);
  }

  return tree;
}

function getWidgetObjectExpression(tree) {
  var lastStatement = tree.body[tree.body.length - 1];

  if (lastStatement && lastStatement.type === 'ExpressionStatement' ) {
    var widgetObjectExp = lastStatement.expression;
    if (widgetObjectExp.type === 'ObjectExpression') {
      return widgetObjectExp;
    }
  }

  return undefined;
}

// Rewrites a widget's object literal into a module export: stamps the id,
// compiles the stylus `style` block into scoped `css`, and turns an `ms`-style
// refreshFrequency string into milliseconds.
function transform(src, widgetId) {
  var tree = esprima.parse(src);
  return tree ? escodegen.generate(modifyAST(tree, widgetId)) : '';
}

module.exports = {transform: transform};
