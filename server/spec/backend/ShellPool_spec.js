var test = require('tape');
var path = require('path');

var ShellPool = require('../../src/ShellPool');

var workingDir = path.resolve(__dirname, path.join('..', 'test_widgets'));

function withPool(options, body) {
  var pool = ShellPool(
    Object.assign({workingDir: workingDir}, options || {}),
  );
  return body(pool, function run(command) {
    return new Promise(function (resolve, reject) {
      pool.run(command, function (err, result) {
        if (err) reject(err);
        else resolve(result);
      });
    });
  }).then(
    function (v) {
      pool.shutdown();
      return v;
    },
    function (e) {
      pool.shutdown();
      throw e;
    },
  );
}

test('running commands', function (t) {
  t.plan(4);
  withPool(null, function (pool, run) {
    return run('echo "yay"')
      .then(function (r) {
        t.equal(r.stdout, 'yay\n', 'it returns stdout');
        t.equal(r.stderr, '', 'stderr is separate and empty');
        t.equal(r.exitCode, 0, 'it reports the exit code');
        return run('pwd');
      })
      .then(function (r) {
        t.equal(r.stdout, workingDir + '\n', 'it runs in the working dir');
      });
  });
});

test('streams and exit codes are reported separately', function (t) {
  t.plan(4);
  withPool(null, function (pool, run) {
    return run('echo out; echo err >&2; exit 7').then(function (r) {
      t.equal(r.stdout, 'out\n', 'stdout holds only stdout');
      t.equal(r.stderr, 'err\n', 'stderr holds only stderr');
      t.equal(r.exitCode, 7, 'the exit code survives');
      return run('true').then(function (ok) {
        t.equal(ok.exitCode, 0, 'a later command is unaffected');
      });
    });
  });
});

test('bash error messages keep their original line numbers', function (t) {
  t.plan(2);
  withPool(null, function (pool, run) {
    return run('fake-command')
      .then(function (r) {
        t.equal(
          r.stderr,
          'bash: line 1: fake-command: command not found\n',
          'a single-line command reports line 1',
        );
        return run('echo a\necho b\nfake-command');
      })
      .then(function (r) {
        t.equal(
          r.stderr,
          'bash: line 3: fake-command: command not found\n',
          'a multi-line command reports the failing line',
        );
      });
  });
});

test('commands run with stdin at EOF', function (t) {
  t.plan(2);
  withPool(null, function (pool, run) {
    // A command reading stdin must not consume the control channel: if it did,
    // it would swallow the next widget's command text.
    return run('read x; echo "[$x]"')
      .then(function (r) {
        t.equal(r.stdout, '[]\n', 'reading stdin yields nothing');
        return run('echo survived');
      })
      .then(function (r) {
        t.equal(r.stdout, 'survived\n', 'the next command is unaffected');
      });
  });
});

test('commands cannot leak state into later ticks', function (t) {
  t.plan(2);
  withPool(null, function (pool, run) {
    return run('cd /; export LEAKED=1; echo done')
      .then(function (r) {
        t.equal(r.stdout, 'done\n', 'the command runs');
        return run('pwd; echo "[$LEAKED]"');
      })
      .then(function (r) {
        t.equal(
          r.stdout,
          workingDir + '\n[]\n',
          'cd and export did not escape the subshell',
        );
      });
  });
});

test('the shell persists between ticks', function (t) {
  t.plan(2);
  withPool(null, function (pool, run) {
    var first;
    return run('echo $$')
      .then(function (r) {
        first = r.stdout.trim();
        t.ok(/^[0-9]+$/.test(first), 'the shell reports a pid');
        return run('echo $$');
      })
      .then(function (r) {
        t.equal(
          r.stdout.trim(),
          first,
          'the same command reuses the same shell process',
        );
      });
  });
});

test('distinct commands get distinct shells', function (t) {
  t.plan(1);
  withPool(null, function (pool, run) {
    return Promise.all([run('echo $$'), run('echo $$ # other')]).then(function (
      rs,
    ) {
      t.notEqual(
        rs[0].stdout.trim(),
        rs[1].stdout.trim(),
        'they do not share a shell',
      );
    });
  });
});

test('a hung command trips the watchdog and the pool recovers', function (t) {
  t.plan(2);
  withPool({watchdog: 400}, function (pool, run) {
    return run('sleep 30')
      .then(
        function () {
          t.fail('it should not have resolved');
        },
        function (err) {
          t.ok(/exceeded/.test(err.message), 'it reports the timeout');
        },
      )
      .then(function () {
        return run('echo alive');
      })
      .then(function (r) {
        t.equal(r.stdout, 'alive\n', 'a fresh shell serves the next command');
      });
  });
});

test('output containing the framing byte is not mistaken for a sentinel', function (t) {
  t.plan(1);
  withPool(null, function (pool, run) {
    return run('printf "a\\036b\\036c\\n"').then(function (r) {
      t.equal(r.stdout, 'a\x1eb\x1ec\n', 'the payload survives intact');
    });
  });
});

test('a closed pool refuses work', function (t) {
  t.plan(1);
  var pool = ShellPool({workingDir: workingDir});
  pool.shutdown();
  pool.run('echo hi', function (err) {
    t.ok(err && /closed/.test(err.message), 'it errors instead of spawning');
    t.end();
  });
});
