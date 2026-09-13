'use strict';

// Pool of persistent bash processes, one per distinct command.
//
// Commands arrive on the shell's fd 3, never stdin: a widget command containing
// `read`, a bare `cat`, `xargs` or `ssh host uptime` would otherwise consume the
// next command's text off stdin and desynchronize the protocol.
//
// Wire format on fd 3: a nonce line, the command's lines verbatim, then the
// nonce again as terminator. Framing is reassembled with `read` and string
// append, both bash builtins, so a tick forks only for the subshell that runs
// the command. Encoding the payload instead would cost an external decoder and
// a command substitution per tick -- two extra forks, which measured slower
// than the fresh `bash` this pool exists to avoid.
//
// The reassembled command is prefixed with a newline. Without it bash omits the
// line number from errors in single-line commands; with it, `bash: line 1: ...`
// matches what a fresh bash reading the command on stdin reports.
//
// Replies are sentinel-framed per stream:
//     stdout: \x1e<nonce> <exit code>\x1e\n
//     stderr: \x1e<nonce>\x1e\n
//
// The driver must stay on ONE physical line; a multi-line driver makes bash
// report its own line numbers instead of the command's.

const {spawn} = require('child_process');
const crypto = require('crypto');

const RS = '\x1e';

const DRIVER =
  "__ubnl=$'\\n'; " +
  'while IFS= read -r __ubn <&3; do ' +
  '__ubc=$__ubnl; ' +
  'while IFS= read -r __ubl <&3; do ' +
  '[ "$__ubl" = "$__ubn" ] && break; ' +
  '__ubc="$__ubc$__ubl$__ubnl"; ' +
  'done; ' +
  '( eval "$__ubc" ) </dev/null; ' +
  '__ubr=$?; ' +
  'printf \'\\036%s %d\\036\\n\' "$__ubn" "$__ubr"; ' +
  'printf \'\\036%s\\036\\n\' "$__ubn" >&2; ' +
  'done';

const DEFAULTS = {
  idleTimeout: 5 * 60 * 1000,
  watchdog: 30 * 1000,
  maxShells: 64,
};

function Shell(workingDir, loginShell, onExit) {
  const args = loginShell ? ['-l', '-c', DRIVER] : ['-c', DRIVER];
  const proc = spawn('bash', args, {
    cwd: workingDir,
    stdio: ['ignore', 'pipe', 'pipe', 'pipe'],
  });

  const api = {proc, control: proc.stdio[3], alive: true};

  let out = '';
  let err = '';
  let pending = null;

  function settle() {
    if (!pending || pending.outDone === null || pending.errDone === null) return;
    const done = pending;
    pending = null;
    clearTimeout(done.timer);
    done.cb(null, {
      stdout: done.outDone,
      stderr: done.errDone,
      exitCode: done.code,
    });
  }

  // A sentinel can be split across chunk boundaries, so scan the accumulated
  // buffer rather than each chunk.
  proc.stdout.setEncoding('utf8');
  proc.stdout.on('data', (chunk) => {
    out += chunk;
    if (!pending) return;
    const mark = RS + pending.nonce + ' ';
    const at = out.indexOf(mark);
    if (at === -1) return;
    const end = out.indexOf(RS, at + mark.length);
    if (end === -1) return;
    pending.code = parseInt(out.slice(at + mark.length, end), 10);
    pending.outDone = out.slice(0, at);
    out = out.slice(end + 1).replace(/^\n/, '');
    settle();
  });

  proc.stderr.setEncoding('utf8');
  proc.stderr.on('data', (chunk) => {
    err += chunk;
    if (!pending) return;
    const mark = RS + pending.nonce + RS;
    const at = err.indexOf(mark);
    if (at === -1) return;
    pending.errDone = err.slice(0, at);
    err = err.slice(at + mark.length).replace(/^\n/, '');
    settle();
  });

  function fail(reason) {
    api.alive = false;
    const done = pending;
    pending = null;
    if (done) {
      clearTimeout(done.timer);
      done.cb(new Error(reason), null);
    }
    onExit(api);
  }

  proc.on('error', (e) => fail(e.message));
  proc.on('close', () => fail('shell exited'));

  api.busy = () => pending !== null;

  api.send = function send(command, watchdog, cb) {
    const nonce = 'UB' + crypto.randomBytes(9).toString('hex');
    pending = {
      nonce,
      cb,
      code: 0,
      outDone: null,
      errDone: null,
      timer: setTimeout(() => {
        proc.kill('SIGKILL');
        fail('command exceeded ' + watchdog + 'ms');
      }, watchdog),
    };
    out = '';
    err = '';
    // Trailing newline stripped first: it would otherwise send a blank line the
    // driver appends as an extra line of the command.
    const lines = command.replace(/\n$/, '').split('\n');
    api.control.write(nonce + '\n' + lines.join('\n') + '\n' + nonce + '\n');
  };

  api.kill = function kill() {
    api.alive = false;
    try {
      api.control.end();
      proc.kill();
    } catch (e) {
      /* already gone */
    }
  };

  return api;
}

module.exports = function ShellPool(options) {
  const opts = Object.assign({}, DEFAULTS, options || {});
  const shells = new Map();
  const queues = new Map();
  let closed = false;

  function keyOf(command) {
    return crypto.createHash('sha1').update(command).digest('hex');
  }

  function drop(key) {
    const s = shells.get(key);
    if (s) {
      clearTimeout(s.idleTimer);
      shells.delete(key);
    }
  }

  function evictOldest() {
    let oldestKey = null;
    let oldestAt = Infinity;
    shells.forEach((s, k) => {
      if (!s.busy() && s.lastUsed < oldestAt) {
        oldestAt = s.lastUsed;
        oldestKey = k;
      }
    });
    if (oldestKey !== null) {
      shells.get(oldestKey).kill();
      drop(oldestKey);
    }
  }

  function shellFor(key) {
    let s = shells.get(key);
    if (s && s.alive) return s;
    if (closed) return null;
    if (shells.size >= opts.maxShells) evictOldest();
    s = Shell(opts.workingDir, opts.loginShell, (dead) => {
      if (shells.get(key) === dead) drop(key);
    });
    s.lastUsed = 0;
    shells.set(key, s);
    return s;
  }

  function pump(key) {
    const q = queues.get(key);
    if (!q || !q.length) return;
    const shell = shellFor(key);
    if (!shell) {
      while (q.length) q.shift().cb(new Error('pool is closed'), null);
      return;
    }
    if (shell.busy()) return;

    const job = q.shift();
    clearTimeout(shell.idleTimer);
    shell.lastUsed = Date.now();

    shell.send(job.command, opts.watchdog, (err, result) => {
      if (err && !job.retried && !q.retryBlocked) {
        // The shell died between ticks (idle reaped by the OS, killed, crashed).
        // One relaunch is honest recovery; a second would mask a command that
        // kills its own shell every time.
        job.retried = true;
        q.unshift(job);
        drop(key);
        pump(key);
        return;
      }
      if (err) job.cb(err, null);
      else job.cb(null, result);

      const s = shells.get(key);
      if (s && s.alive) {
        s.idleTimer = setTimeout(() => {
          s.kill();
          drop(key);
        }, opts.idleTimeout);
        if (s.idleTimer.unref) s.idleTimer.unref();
      }
      pump(key);
    });
  }

  return {
    run(command, cb) {
      if (closed) return cb(new Error('pool is closed'), null);
      const key = keyOf(command);
      if (!queues.has(key)) queues.set(key, []);
      queues.get(key).push({command, cb, retried: false});
      pump(key);
    },

    size() {
      return shells.size;
    },

    shutdown() {
      closed = true;
      shells.forEach((s) => s.kill());
      shells.clear();
      queues.clear();
    },
  };
};
