const test = require('tape');
const path = require('path');
const vm = require('vm');
const bundleWidget = require('../../src/bundleWidget');

const testDir = path.resolve(__dirname, path.join('..', 'test_widgets'));

// A bundle registers itself on globalThis.__ubWidgets rather than returning a
// value, so evaluating one needs a context to register into.
function evaluate(src, id) {
  const sandbox = {globalThis: null, console: console};
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(src.toString(), sandbox);
  return sandbox.__ubWidgets && sandbox.__ubWidgets[id];
}

function bundles(t, file, id, check) {
  const bundle = bundleWidget(id, path.join(testDir, file));
  bundle.bundle((err, src) => {
    check(err, src);
    bundle.close();
    t.end();
  });
}

test('bundling coffeescript widgets', (t) => {
  bundles(t, 'widget-1.coffee', 'widget-1', (err, src) => {
    t.notOk(err, 'it bundles without error');
    t.ok(src.indexOf('command') > -1, 'the widget body survives');
    const widget = evaluate(src, 'widget-1');
    t.equal(typeof widget, 'object', 'it registers itself under its id');
    t.equal(widget.id, 'widget-1', 'widgetify stamped the id on it');
  });
});

test('bundling javascript widgets', (t) => {
  bundles(t, 'widget-2.js', 'widget-2', (err, src) => {
    t.notOk(err, 'it bundles without error');
    const widget = evaluate(src, 'widget-2');
    t.equal(widget.id, 'widget-2', 'a classic js widget registers too');
  });
});

test('bundling jsx widgets', (t) => {
  bundles(t, 'widget-3.jsx', 'widget-3', (err, src) => {
    t.notOk(err, 'it bundles without error');
    t.ok(src.indexOf('command') > -1, 'the widget body survives');
    const widget = evaluate(src, 'widget-3');
    t.ok(widget && widget.command, 'its exports are reachable');
  });
});

test('a syntax error is reported, not thrown', (t) => {
  bundles(t, 'broken-widget.coffee', 'broken', (err, src) => {
    t.ok(err, 'it reports an error');
    t.ok(err.message, 'the error carries a message');
    t.notOk(src, 'and yields no source');
  });
});

test('jsx widgets resolve uebersicht to the page copy', (t) => {
  bundles(t, 'widget-3.jsx', 'widget-3b', (err, src) => {
    t.notOk(err, 'it bundles');
    t.equal(
      src.toString().indexOf('react/cjs'),
      -1,
      'React is not bundled into the widget',
    );
  });
});
