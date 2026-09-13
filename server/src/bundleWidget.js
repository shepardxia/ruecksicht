'use strict';

// Bundles one widget.
//
// A widget bundle is an IIFE that registers its exports on globalThis.__ubWidgets
// under the widget's id; the page reads it from there once the script tag
// loads. `uebersicht` resolves to the page's own copy via globalThis.__ubersicht,
// so React, emotion and the shell helper are shared rather than duplicated per
// widget -- a bundled second React would make every hook throw.
//
// Node builtins are aliased to browser shims. esbuild fails the build on an
// unshimmed builtin where browserify silently substituted one, and widgets in
// the wild do require('path').

const esbuild = require('esbuild');
const path = require('path');
const transformWidget = require('./transformWidget');
const {EventEmitter} = require('events');

const SHIMS = {
  path: 'path-browserify',
  events: 'events',
  util: 'util',
  buffer: 'buffer',
  process: 'process',
  stream: 'stream-browserify',
  os: 'os-browserify',
  assert: 'assert',
  url: 'url',
  querystring: 'querystring-es3',
  http: 'stream-http',
  https: 'https-browserify',
  crypto: 'crypto-browserify',
  zlib: 'browserify-zlib',
  tty: 'tty-browserify',
  domain: 'domain-browser',
  constants: 'constants-browserify',
  timers: 'timers-browserify',
  vm: 'vm-browserify',
};

const UEBERSICHT_SHIM = 'module.exports = globalThis.__ubersicht;';

function esbuildError(filePath, error) {
  const first = (error.errors && error.errors[0]) || {};
  const location = first.location || {};
  return {
    message: first.text || error.message,
    line: location.line,
    column: location.column,
    annotated: location.lineText
      ? [{lineNum: location.line, line: location.lineText}]
      : undefined,
    path: location.file || filePath,
  };
}

module.exports = function bundleWidget(id, filePath) {
  const emitter = new EventEmitter();
  const isJsx = /\.jsx$/.test(filePath);
  const isCoffee = /\.coffee$/.test(filePath);
  let context = null;
  let announceRebuilds = false;

  const resolveShims = {
    name: 'ub-resolve',
    setup(build) {
      build.onResolve({filter: /^uebersicht$/}, () => ({
        path: 'uebersicht',
        namespace: 'ub-shim',
      }));

      build.onLoad({filter: /.*/, namespace: 'ub-shim'}, () => ({
        contents: UEBERSICHT_SHIM,
        loader: 'js',
      }));

      Object.keys(SHIMS).forEach((builtin) => {
        const filter = new RegExp('^(node:)?' + builtin + '$');
        build.onResolve({filter: filter}, (args) => {
          try {
            return {path: require.resolve(SHIMS[builtin], {paths: [__dirname]})};
          } catch (e) {
            return null;
          }
        });
      });
    },
  };

  const transformWidgetSource = {
    name: 'ub-widget-source',
    setup(build) {
      const fs = require('fs');

      if (isCoffee) {
        build.onLoad({filter: /\.coffee$/}, (args) => {
          const source = fs.readFileSync(args.path, 'utf8');
          // Only the entry is a widget; an imported .coffee is just a module.
          const contents =
            args.path === filePath
              ? transformWidget(source, id, true)
              : require('coffee-script/lib/coffee-script/coffee-script.js')
                  .compile(source, {bare: true, header: false});
          return {contents: contents, loader: 'js'};
        });
      }

      if (!isJsx && !isCoffee) {
        const entryFilter = new RegExp(
          filePath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$',
        );
        build.onLoad({filter: entryFilter}, (args) => {
          const source = fs.readFileSync(args.path, 'utf8');
          return {contents: transformWidget(source, id, false), loader: 'js'};
        });
      }
    },
  };

  const announce = {
    name: 'ub-announce',
    setup(build) {
      build.onEnd(() => {
        if (announceRebuilds) emitter.emit('update', [filePath]);
      });
    },
  };

  const options = {
    entryPoints: [filePath],
    bundle: true,
    write: false,
    format: 'iife',
    globalName: '__ubWidget',
    platform: 'browser',
    target: 'safari15',
    sourcemap: isJsx ? 'inline' : false,
    logLevel: 'silent',
    absWorkingDir: path.dirname(filePath),
    footer: {
      js:
        'globalThis.__ubWidgets=globalThis.__ubWidgets||{};' +
        'globalThis.__ubWidgets[' +
        JSON.stringify(id) +
        ']=__ubWidget&&__ubWidget.default&&Object.keys(__ubWidget).length===1' +
        '?__ubWidget.default:__ubWidget;',
    },
    plugins: [resolveShims, transformWidgetSource, announce],
  };

  if (isJsx) {
    options.jsx = 'transform';
    options.jsxFactory = 'html';
    options.jsxFragment = 'html.Fragment';
    options.loader = {'.js': 'jsx'};
  }

  const api = emitter;

  api.bundle = function bundle(callback) {
    const built = context
      ? context.rebuild()
      : esbuild.context(options).then((ctx) => {
          context = ctx;
          return ctx.rebuild().then((result) => {
            // Watching only after the first build so the initial result is not
            // announced as an update.
            return ctx.watch().then(() => {
              announceRebuilds = true;
              return result;
            });
          });
        });

    built.then(
      (result) => {
        const out = result.outputFiles && result.outputFiles[0];
        callback(null, Buffer.from(out ? out.contents : new Uint8Array()));
      },
      (err) => callback(esbuildError(filePath, err), null),
    );
  };

  api.close = function close() {
    announceRebuilds = false;
    if (context) {
      context.dispose();
      context = null;
    }
    emitter.removeAllListeners();
  };

  return api;
};
