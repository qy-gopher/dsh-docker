import { createConnection, isIP } from 'node:net';
import { resolveBindHost, resolvePort } from './web-options.mjs';

try {
  const host = resolveBindHost();
  const port = resolvePort();
  const authority = `${isIP(host) === 6 ? `[${host}]` : host}:${port}`;
  // A direct local TCP probe also works when model/QQ traffic uses an HTTP proxy.
  const socket = createConnection({ host, port: Number(port) });
  let header = '';
  let completed = false;
  const finish = (ok) => {
    if (completed) return;
    completed = true;
    socket.destroy();
    process.exitCode = ok ? 0 : 1;
  };
  socket.setTimeout(3000, () => finish(false));
  socket.once('error', () => finish(false));
  socket.once('end', () => finish(false));
  socket.once('connect', () => socket.write(`GET / HTTP/1.1\r\nHost: ${authority}\r\nConnection: close\r\n\r\n`));
  socket.on('data', (chunk) => {
    header += chunk.toString('latin1');
    if (header.includes('\r\n')) {
      const match = /^HTTP\/1\.[01] (\d{3})(?: |\r\n)/.exec(header);
      const status = match ? Number(match[1]) : 0;
      // The root is authenticated in DSH: 401 is the expected anonymous response.
      finish((status >= 200 && status < 400) || status === 401);
    } else if (header.length > 8192) {
      finish(false);
    }
  });
} catch {
  process.exitCode = 1;
}
