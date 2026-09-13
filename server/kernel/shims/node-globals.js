import {Buffer as NodeBuffer} from 'buffer';
export const Buffer = NodeBuffer;
export const process = {
  env: {NODE_ENV: 'production'},
  platform: 'darwin',
  arch: 'arm64',
  version: 'v22.0.0',
  versions: {node: '22.0.0'},
  argv: ['node'],
  pid: 1,
  cwd: () => '/',
  chdir: () => {},
  nextTick: (fn, ...args) => fn(...args),
  on: () => {},
  once: () => {},
  emit: () => {},
  exit: () => {},
  hrtime: () => [0, 0],
  stdout: {write: () => true, isTTY: false},
  stderr: {write: () => true, isTTY: false},
};
