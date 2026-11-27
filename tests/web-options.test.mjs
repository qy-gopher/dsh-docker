import assert from 'node:assert/strict';
import { test } from 'node:test';
import { resolveBindHost, resolvePort, resolveWebArguments } from '../scripts/web-options.mjs';

const interfaces = {
  lo: [{ address: '127.0.0.1', internal: true }],
  eth0: [{ address: '172.20.0.2', internal: false }],
};

test('the default Web command binds a concrete container IP', () => {
  assert.deepEqual(resolveWebArguments({}, interfaces), [
    'web', '--no-open', '--host', '172.20.0.2', '--port', '3080',
  ]);
});

test('a public URL automatically trusts its browser-visible authority', () => {
  assert.deepEqual(resolveWebArguments({
    DSH_PUBLIC_URL: 'https://nas.example.com:8443/dsh',
    DSH_TRUSTED_HOSTS: 'nas.example.com:8443,192.168.1.20 example.net',
  }, interfaces), [
    'web', '--no-open', '--host', '172.20.0.2', '--port', '3080',
    '--public-url', 'https://nas.example.com:8443/dsh/',
    '--trusted-host', 'nas.example.com:8443',
    '--trusted-host', '192.168.1.20',
    '--trusted-host', 'example.net',
  ]);
});

test('IPv6-only containers and an explicit loopback bind are supported', () => {
  assert.equal(resolveBindHost({}, { eth0: [{ address: 'fd00::2', internal: false }] }), 'fd00::2');
  assert.equal(resolveBindHost({ DSH_BIND_HOST: '127.0.0.1' }, {}), '127.0.0.1');
});

test('wildcard binds fail before launching DSH', () => {
  for (const host of ['0.0.0.0', '::', 'localhost']) {
    assert.throws(() => resolveBindHost({ DSH_BIND_HOST: host }, interfaces), /concrete/);
  }
  assert.throws(() => resolveBindHost({}, {}), /No container IP/);
});

test('invalid ports and public roots fail with a configuration error', () => {
  for (const port of ['0', '65536', '3.5', '-1', 'abc']) {
    assert.throws(() => resolvePort({ DSH_PORT: port }), /DSH_PORT/);
  }
  for (const url of ['nas.example.com', 'ftp://example.com/', 'https://user:secret@example.com/', 'https://example.com/?token=secret']) {
    assert.throws(() => resolveWebArguments({ DSH_PUBLIC_URL: url }, interfaces), /DSH_PUBLIC_URL/);
  }
});
