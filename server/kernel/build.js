#!/usr/bin/env node
'use strict';

// Builds the transform kernel the Swift daemon evaluates in JavaScriptCore.
//
// Two things make this more than an esbuild invocation. Stylus resolves its own
// function library and nib's mixins through the filesystem, so those .styl files
// are baked into a virtual one. And stylus dispatches its visitors on
// `node.constructor.name`, so the bundle must keep original symbol names or a
// renamed class silently returns the AST where CSS should be.

const fs = require('fs');
const path = require('path');
const {execFileSync} = require('child_process');

const KERNEL = __dirname;
const SERVER = path.dirname(KERNEL);
const OUT = path.resolve(
  SERVER,
  '../core/Sources/UebersichtCore/Resources/transform-kernel.js',
);
const modules = (...parts) => path.join(SERVER, 'node_modules', ...parts);

function stylFiles(root) {
  const found = [];
  (function walk(dir) {
    for (const entry of fs.readdirSync(dir)) {
      const full = path.join(dir, entry);
      if (fs.statSync(full).isDirectory()) walk(full);
      else if (full.endsWith('.styl')) found.push(full);
    }
  })(root);
  return found;
}

function virtualFilesystem() {
  const files = {};

  // Resolved relative to __dirname, which the bundle defines as "/".
  for (const file of stylFiles(modules('stylus/lib'))) {
    files['/' + path.relative(modules('stylus/lib'), file)] = fs.readFileSync(file, 'utf8');
  }

  // nib is reached by several spellings depending on which file imports it, so
  // it is registered under each rather than guessing which one stylus will use.
  for (const file of stylFiles(modules('nib/lib'))) {
    const rel = path.relative(modules('nib/lib'), file);
    const body = fs.readFileSync(file, 'utf8');
    for (const key of ['/nib/' + rel, '/' + rel, rel, rel.replace(/^nib\//, ''), path.basename(file)]) {
      if (!(key in files)) files[key] = body;
    }
  }
  for (const key of ['nib.styl', '/nib.styl', '/nib/nib.styl']) {
    files[key] = files['nib/index.styl'];
  }

  // Stylus probes statSync().isDirectory() to decide whether `@import x` means
  // x.styl or x/index.styl, so directories have to exist too.
  const dirs = new Set();
  for (const key of Object.keys(files)) {
    let dir = path.dirname(key);
    while (dir && dir !== '.' && dir !== '/') {
      dirs.add(dir);
      dir = path.dirname(dir);
    }
  }

  return `const FILES = ${JSON.stringify(files)};
const DIRS = new Set(${JSON.stringify([...dirs])});
const has = (p) => Object.prototype.hasOwnProperty.call(FILES, String(p));

module.exports = {
  existsSync: (p) => has(p) || DIRS.has(String(p)),
  readFileSync: (p) => {
    if (has(p)) return FILES[String(p)];
    throw Object.assign(new Error('ENOENT: ' + p), {code: 'ENOENT'});
  },
  statSync: (p) => {
    const key = String(p);
    if (DIRS.has(key)) return {isDirectory: () => true, isFile: () => false, mtime: new Date(0)};
    if (has(key)) return {isDirectory: () => false, isFile: () => true, mtime: new Date(0)};
    throw Object.assign(new Error('ENOENT: ' + key), {code: 'ENOENT'});
  },
  readdirSync: () => [],
};
`;
}

const generated = path.join(KERNEL, 'shims', 'fs.generated.js');
fs.writeFileSync(generated, virtualFilesystem());

const shim = (name) => path.join(KERNEL, 'shims', name);

execFileSync(
  modules('.bin/esbuild'),
  [
    path.join(KERNEL, 'entry.js'),
    '--bundle',
    '--format=iife',
    '--platform=browser',
    '--target=safari15',
    // Stylus dispatches on constructor.name; renaming breaks its visitors.
    '--keep-names',
    `--alias:fs=${generated}`,
    `--alias:canvas=${shim('empty.js')}`,
    `--alias:module=${shim('empty.js')}`,
    `--alias:child_process=${shim('empty.js')}`,
    `--alias:nib=${shim('nib.js')}`,
    `--alias:stylus=${modules('stylus/lib/stylus.js')}`,
    '--alias:path=path-browserify',
    '--alias:crypto=crypto-browserify',
    '--alias:vm=vm-browserify',
    '--alias:stream=stream-browserify',
    '--alias:os=os-browserify',
    '--alias:util=util',
    '--alias:events=events',
    '--alias:buffer=buffer',
    '--define:global=globalThis',
    '--define:__dirname="/"',
    '--define:__filename="/kernel.js"',
    `--inject:${shim('node-globals.js')}`,
    `--outfile=${OUT}`,
  ],
  {stdio: 'inherit', cwd: SERVER},
);

process.stdout.write(`kernel: ${fs.statSync(OUT).size} bytes -> ${OUT}\n`);
