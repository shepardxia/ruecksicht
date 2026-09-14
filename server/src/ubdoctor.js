'use strict';

// Scans a widget directory and reports what a migration would touch, so every
// qualitative "this might break" becomes a count before any of it is attempted.
//
// Findings are advisory and conservative: this reads source text, it does not
// execute widgets, so `warn` means "a human should look", never "this is
// broken". False positives here are far cheaper than a widget that silently
// stops on upgrade.

const fs = require('fs');
const path = require('path');

const SOURCE_EXT = ['.jsx', '.js', '.coffee'];

const NODE_BUILTINS = [
  'fs',
  'path',
  'os',
  'child_process',
  'http',
  'https',
  'net',
  'crypto',
  'util',
  'events',
  'stream',
  'buffer',
  'zlib',
];

function lineOf(source, index) {
  return source.slice(0, index).split('\n').length;
}

function scanSource(source) {
  const findings = [];

  function flag(code, severity, detail, index) {
    findings.push({
      code: code,
      severity: severity,
      detail: detail,
      line: index === undefined ? null : lineOf(source, index),
    });
  }

  function each(re, fn) {
    let m;
    const rx = new RegExp(re.source, re.flags.indexOf('g') === -1 ? re.flags + 'g' : re.flags);
    while ((m = rx.exec(source)) !== null) fn(m);
  }

  // A sub-second data clock is the single biggest energy lever: it almost
  // always means the author wanted motion, not data, and had only one clock.
  each(/refreshFrequency\s*[:=]\s*(\d+)/, (m) => {
    const ms = parseInt(m[1], 10);
    if (ms < 1000) {
      flag(
        'fast-data-clock',
        'warn',
        'refreshFrequency is ' +
          ms +
          'ms; if this drives motion rather than data, move it to animate()',
        m.index,
      );
    }
  });

  each(/refreshFrequency\s*[:=]\s*['"]([^'"]+)['"]/, (m) => {
    flag(
      'ms-string-frequency',
      'info',
      'refreshFrequency given as the string "' + m[1] + '"',
      m.index,
    );
  });

  // A persistent shell keeps one pid across ticks, so $$ stops being unique.
  each(/\$\$|\$PPID/, (m) => {
    flag(
      'unstable-pid',
      'warn',
      '$$ / $PPID is stable across ticks under a persistent shell; ' +
        'temp-file names built from it will now collide',
      m.index,
    );
  });

  each(/\b4141[67]\b/, (m) => {
    flag(
      'hardcoded-port',
      'warn',
      'hardcoded port ' + m[0] + '; use a relative URL instead',
      m.index,
    );
  });

  each(/process\.argv\s*\[\s*0\s*\]/, (m) => {
    flag(
      'process-argv',
      'warn',
      'process.argv[0] resolves to a shim; breaks without a PATH node',
      m.index,
    );
  });

  each(/require\(\s*['"]([^'"]+)['"]\s*\)/, (m) => {
    if (NODE_BUILTINS.indexOf(m[1]) !== -1) {
      flag(
        'node-builtin',
        'warn',
        "require('" + m[1] + "') needs a bundler shim once browserify is gone",
        m.index,
      );
    }
  });

  // A background job used to be orphaned when its shell exited each tick; now
  // it stays a child, and its late output can land in a later tick's buffer.
  // Matches a trailing `&` whether the command is a bare shell line or embedded
  // in a quoted string, without catching `&&` or an fd redirect like 2>&1.
  each(/[^&\s|]\s*&(?=\s*(?:["'`]|\r?\n|$))/m, (m) => {
    flag(
      'background-job',
      'warn',
      'backgrounded command stays a child of the persistent shell',
      m.index,
    );
  });

  each(/\bsleep\s+(\d+)/, (m) => {
    if (parseInt(m[1], 10) >= 30) {
      flag(
        'long-command',
        'warn',
        'sleep ' + m[1] + 's may trip the 30s watchdog',
        m.index,
      );
    }
  });

  each(/export\s+const\s+command\s*=\s*(?:async\s*)?(?:\(|function)/, (m) => {
    flag(
      'function-command',
      'info',
      'function command runs in the page; it cannot be hoisted or shared across screens',
      m.index,
    );
  });

  each(/\.gif\b/, (m) => {
    flag(
      'gif-animation',
      'info',
      'animated GIFs decode on the CPU continuously; a sprite strip animates on the compositor',
      m.index,
    );
  });

  if (/\banimate\s*[:=]/.test(source) || /export\s+const\s+animate\b/.test(source)) {
    flag('uses-animate', 'ok', 'already uses the animation clock');
  }

  return findings;
}

function readWidgetSources(widgetDir) {
  let entries;
  try {
    entries = fs.readdirSync(widgetDir);
  } catch (e) {
    return [];
  }
  return entries
    .filter((f) => SOURCE_EXT.indexOf(path.extname(f)) !== -1)
    .filter((f) => !/\.disabled$/.test(f))
    .map((f) => path.join(widgetDir, f));
}

function scanDirectory(root) {
  let entries;
  try {
    entries = fs.readdirSync(root);
  } catch (e) {
    return {error: 'cannot read ' + root, widgets: [], summary: {}};
  }

  const widgets = entries
    .filter((name) => /\.widget$/.test(name))
    .filter((name) => {
      try {
        return fs.statSync(path.join(root, name)).isDirectory();
      } catch (e) {
        return false;
      }
    })
    .map((name) => {
      const dir = path.join(root, name);
      const files = readWidgetSources(dir).map((file) => {
        const source = fs.readFileSync(file, 'utf8');
        return {
          file: path.relative(root, file),
          language: path.extname(file) === '.coffee' ? 'coffeescript' : 'jsx',
          findings: scanSource(source),
        };
      });
      return {
        name: name,
        files: files,
        findings: files.reduce((all, f) => all.concat(f.findings), []),
      };
    });

  const summary = {};
  widgets.forEach((w) =>
    w.findings.forEach((f) => {
      summary[f.code] = (summary[f.code] || 0) + 1;
    }),
  );

  return {
    root: root,
    widgets: widgets,
    summary: summary,
    widgetCount: widgets.length,
    cleanCount: widgets.filter(
      (w) => !w.findings.some((f) => f.severity === 'warn'),
    ).length,
  };
}

module.exports = scanDirectory;
