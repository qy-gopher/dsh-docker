// Run inside the smoke container against the installed DSH sandbox provider.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { homedir, tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { pathToFileURL } from 'node:url';

assert.equal(process.getuid(), 1000, 'The sandbox must work as the node user.');
const runtimeRequire = createRequire('/opt/dsh/package.json');
const { Context } = await import(pathToFileURL(runtimeRequire.resolve('@deepseek-ai/cordis')));
const { LocalSandboxProvider } = await import(pathToFileURL(runtimeRequire.resolve('@deepseek-ai/dsh-sandbox-local')));
const context = new Context();
const root = mkdtempSync(join(homedir(), 'workspaces/default/.sandbox-smoke-'));
const workspace = join(root, 'workspace');
const granted = join(root, 'granted');
const denied = join(root, 'denied');
for (const directory of [workspace, granted, denied]) mkdirSync(directory);
const workspaceFile = join(workspace, 'state');
const grantedFile = join(granted, 'state');
const deniedFile = join(denied, 'state');
// All targets are writable by this user before confinement.
for (const file of [workspaceFile, grantedFile, deniedFile]) writeFileSync(file, 'original');
const tempFile = join(tmpdir(), basename(root));
const pidNamespace = readlinkSync('/proc/self/ns/pid');
const command = String.raw`
  const assert = require('node:assert/strict');
  const fs = require('node:fs');
  const [mode, workspace, granted, denied, temp, parentPidNamespace] = process.argv.slice(1);
  assert.notEqual(fs.readlinkSync('/proc/self/ns/pid'), parentPidNamespace);
  if (mode === 'workspace-write') {
    fs.writeFileSync(workspace, 'workspace-write');
    fs.writeFileSync(granted, 'granted-write');
    fs.writeFileSync(temp, 'private-temp');
  } else {
    for (const path of [workspace, granted, temp]) {
      assert.throws(() => fs.writeFileSync(path, 'forbidden'), { code: 'EROFS' });
    }
  }
  assert.throws(() => fs.writeFileSync(denied, 'forbidden'), { code: 'EROFS' });
`;

try {
  const fiber = context.plugin(LocalSandboxProvider, {});
  await fiber.inertia;
  for (const mode of ['workspace-write', 'read-only']) {
    const wrapped = await context.sandbox.confine(
      [process.execPath, '-e', command, mode, workspaceFile, grantedFile, deniedFile, tempFile, pidNamespace],
      { mode, workspaceRoot: workspace, additionalWritableRoots: [granted] },
    );
    assert.equal(basename(wrapped.argv[0]), 'bwrap', 'DSH must select bubblewrap.');
    assert.equal(wrapped.enforcement, 'full');
    const result = spawnSync(wrapped.argv[0], wrapped.argv.slice(1), {
      cwd: workspace, encoding: 'utf8', timeout: 15000,
    });
    assert.equal(result.status, 0, `${mode}: ${result.error ?? result.stderr}`);
    assert.equal(readFileSync(workspaceFile, 'utf8'), 'workspace-write');
    assert.equal(readFileSync(grantedFile, 'utf8'), 'granted-write');
    assert.equal(readFileSync(deniedFile, 'utf8'), 'original');
    assert.equal(existsSync(tempFile), false, 'Sandbox /tmp must be ephemeral.');
  }
  console.log('DSH selected bwrap: workspace grants, read-only mode, private /tmp and PID namespace passed.');
} finally {
  await context.fiber.dispose();
  rmSync(root, { recursive: true, force: true });
}
