'use strict';

// Middleware serving the results of shell commands on POST /run/.
//
// Commands run in a persistent shell leased from the pool rather than a fresh
// bash per request. The HTTP contract is unchanged: 500 when the command wrote
// anything to stderr, the command's output as the body.

const ShellPool = require('./ShellPool');

module.exports = function commandServer(workingDir, useLoginShell) {
  const pool = ShellPool({workingDir: workingDir, loginShell: !!useLoginShell});

  function middleware(req, res, next) {
    if (req.method !== 'POST' || req.url !== '/run/') return next();

    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const command = Buffer.concat(chunks).toString('utf8');

      pool.run(command, (err, result) => {
        if (err) {
          res.writeHead(500);
          res.end(err.message);
          return;
        }
        res.writeHead(result.stderr ? 500 : 200);
        res.end(result.stdout + result.stderr);
      });
    });
  }

  middleware.close = pool.shutdown;
  middleware.pool = pool;

  return middleware;
};
