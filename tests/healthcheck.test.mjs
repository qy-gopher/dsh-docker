import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import http from 'node:http';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const script = fileURLToPath(new URL('../scripts/healthcheck.mjs', import.meta.url));

for (const [status, expected] of [[200, 0], [401, 0], [500, 1]]) {
  test(`HTTP ${status} gives healthcheck exit ${expected}`, async (t) => {
    const server = http.createServer((_request, response) => {
      response.writeHead(status);
      response.end(status === 401 ? 'authentication required' : 'response');
    });
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    t.after(() => new Promise((resolve) => server.close(resolve)));
    const child = spawn(process.execPath, [script], {
      env: { ...process.env, DSH_BIND_HOST: '127.0.0.1', DSH_PORT: String(server.address().port) },
      stdio: 'ignore',
    });
    const [code] = await once(child, 'exit');
    assert.equal(code, expected);
  });
}
