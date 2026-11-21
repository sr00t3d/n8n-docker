'use strict';

const http = require('http');

const req = http.request(
  {
    host: '127.0.0.1',
    port: Number(process.env.N8N_PORT || 5678),
    path: '/healthz',
    method: 'GET',
    timeout: 4000,
  },
  (res) => {
    process.exit(res.statusCode === 200 ? 0 : 1);
  }
);

req.on('timeout', () => {
  req.destroy();
  process.exit(1);
});

req.on('error', () => {
  process.exit(1);
});

req.end();
