var test = require('tape');
var path = require('path');

var scan = require('../../src/ubdoctor');
var scanSource = scan.scanSource;

function codes(source) {
  return scanSource(source).map(function (f) {
    return f.code;
  });
}

test('it flags a sub-second data clock', function (t) {
  t.ok(
    codes('export const refreshFrequency = 200').indexOf('fast-data-clock') !== -1,
    '200ms is flagged',
  );
  t.equal(
    codes('export const refreshFrequency = 30000').indexOf('fast-data-clock'),
    -1,
    '30s is not',
  );
  t.end();
});

test('it flags what a persistent shell changes', function (t) {
  t.ok(codes('echo > /tmp/x.$$').indexOf('unstable-pid') !== -1, '$$ is flagged');
  t.ok(codes('kill $PPID').indexOf('unstable-pid') !== -1, '$PPID is flagged');
  t.ok(
    codes('export const command = "long-task &"').indexOf('background-job') !== -1,
    'a backgrounded job is flagged',
  );
  t.ok(codes('sleep 45').indexOf('long-command') !== -1, 'a long sleep is flagged');
  t.end();
});

test('it does not mistake && for a background job', function (t) {
  t.equal(
    codes('a && b &&\nc').indexOf('background-job'),
    -1,
    'a trailing && is not a background job',
  );
  t.end();
});

test('it flags what the bundler change touches', function (t) {
  t.ok(
    codes("require('child_process')").indexOf('node-builtin') !== -1,
    'a node builtin is flagged',
  );
  t.equal(
    codes("require('./helper')").indexOf('node-builtin'),
    -1,
    'a relative import is not',
  );
  t.ok(
    codes('fetch("http://127.0.0.1:41417/x")').indexOf('hardcoded-port') !== -1,
    'a hardcoded port is flagged',
  );
  t.ok(
    codes('process.argv[0]').indexOf('process-argv') !== -1,
    'process.argv[0] is flagged',
  );
  t.end();
});

test('it recognises a widget already on the animation clock', function (t) {
  t.ok(
    codes('export const animate = (s, dt) => s').indexOf('uses-animate') !== -1,
    'animate() is recognised',
  );
  t.end();
});

test('findings carry a line number', function (t) {
  var findings = scanSource('line one\nline two\nexport const refreshFrequency = 50');
  var fast = findings.filter(function (f) {
    return f.code === 'fast-data-clock';
  })[0];
  t.equal(fast.line, 3, 'it reports the line the finding is on');
  t.end();
});

test('scanning a directory summarises across widgets', function (t) {
  var report = scan(path.resolve(__dirname, path.join('..', 'test_widgets')));
  t.equal(typeof report.summary, 'object', 'it returns a summary');
  t.ok(Array.isArray(report.widgets), 'it returns a widget list');
  t.equal(typeof report.widgetCount, 'number', 'it counts widgets');
  t.end();
});

test('an unreadable directory reports an error rather than throwing', function (t) {
  var report = scan('/nonexistent-path-for-ubdoctor');
  t.ok(report.error, 'it reports an error');
  t.deepEqual(report.widgets, [], 'and yields no widgets');
  t.end();
});
