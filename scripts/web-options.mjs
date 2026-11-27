import { isIP } from 'node:net';
import { networkInterfaces } from 'node:os';
import { pathToFileURL } from 'node:url';

export function resolveBindHost(env = process.env, interfaces = networkInterfaces()) {
  const configured = env.DSH_BIND_HOST?.trim();
  if (configured && configured !== 'auto') {
    if (!isIP(configured) || configured === '0.0.0.0' || configured === '::') {
      throw new Error('DSH_BIND_HOST must be auto or a concrete IPv4/IPv6 address; DSH rejects wildcard addresses.');
    }
    return configured;
  }
  const names = Object.keys(interfaces).sort((a, b) => Number(b === 'eth0') - Number(a === 'eth0'));
  const addresses = names.flatMap((name) => interfaces[name] ?? []).filter((address) => !address.internal);
  const chosen = addresses.find((address) => isIP(address.address) === 4)
    ?? addresses.find((address) => isIP(address.address) === 6 && !address.address.startsWith('fe80:'));
  if (!chosen) throw new Error('No container IP was found; set DSH_BIND_HOST to a concrete local address.');
  return chosen.address;
}

export function resolvePort(env = process.env) {
  const value = env.DSH_PORT || '3080';
  if (!/^\d+$/.test(value) || Number(value) < 1 || Number(value) > 65535) {
    throw new Error('DSH_PORT must be an integer from 1 to 65535.');
  }
  return String(Number(value));
}

export function resolveWebArguments(env = process.env, interfaces = networkInterfaces()) {
  const args = ['web', '--no-open', '--host', resolveBindHost(env, interfaces), '--port', resolvePort(env)];
  const trustedHosts = new Set((env.DSH_TRUSTED_HOSTS || '').split(/[,\s]+/).filter(Boolean));
  if (env.DSH_PUBLIC_URL?.trim()) {
    let url;
    try {
      url = new URL(env.DSH_PUBLIC_URL.trim());
    } catch {
      throw new Error('DSH_PUBLIC_URL must be an absolute HTTP(S) URL.');
    }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
      throw new Error('DSH_PUBLIC_URL must be an HTTP(S) application root without credentials, query, or fragment.');
    }
    if (!url.pathname.endsWith('/')) url.pathname += '/';
    args.push('--public-url', url.href);
    trustedHosts.add(url.host);
  }
  for (const host of trustedHosts) {
    if (/^[\-]/.test(host) || /[/?#@\s*]/.test(host)) {
      throw new Error('DSH_TRUSTED_HOSTS must contain host or host:port values separated by commas or spaces.');
    }
    args.push('--trusted-host', host);
  }
  return args;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    // NUL-separated argv lets Bash preserve each argument without eval or shell quoting.
    process.stdout.write(resolveWebArguments().join('\0') + '\0');
  } catch (error) {
    process.stderr.write(`dsh-docker: ${error.message}\n`);
    process.exitCode = 1;
  }
}
