import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { execFileSync } from 'node:child_process';

const runtimeRequire = createRequire('/opt/dsh/package.json');
const profileRequire = createRequire('/opt/dsh-seed/profiles/web/package.json');
const yaml = runtimeRequire('js-yaml');
const jsTag = new yaml.Type('tag:yaml.org,2002:js', { kind: 'scalar', construct: (value) => value });
const schema = yaml.DEFAULT_SCHEMA.extend([jsTag]);
const mnemonPackagePath = profileRequire.resolve('dsh-mnemon/package.json');
const mnemonPackage = JSON.parse(readFileSync(mnemonPackagePath, 'utf8'));
const patchPath = mnemonPackage.dsh?.bundle?.patch;
if (typeof patchPath !== 'string') throw new Error('The pinned mnemon package has no single bundle patch.');
const bundle = yaml.load(readFileSync(join(dirname(mnemonPackagePath), patchPath), 'utf8'), { schema });
const matches = [];
function visit(value) {
  if (!value || typeof value !== 'object') return;
  if (value.id === 'mnemon' && value.name === 'dsh-mnemon') matches.push(value);
  for (const child of Object.values(value)) visit(child);
}
visit(bundle);
if (matches.length !== 1 || !matches[0].config) throw new Error('Cannot identify the pinned mnemon default configuration.');

// DSH replaces a whole config object. Carry all pinned defaults into the profile override.
const config = { ...matches[0].config, remoteAccess: 'trusted-host' };
const header = '# Generated from the pinned mnemon bundle during image build.\n'
  + '# The authenticated remote Web UI can manage memory and settings.\n';
writeFileSync('/opt/dsh-seed/profiles/web/cordis.patch.yml', header + yaml.dump([{ id: 'mnemon', config }], { lineWidth: -1, noRefs: true }));

const runtimePackage = JSON.parse(readFileSync('/opt/dsh/package.json', 'utf8'));
const profilePackage = JSON.parse(readFileSync('/opt/dsh-seed/profiles/web/package.json', 'utf8'));
const versions = {
  node: process.versions.node,
  pnpm: execFileSync('pnpm', ['--version'], { encoding: 'utf8' }).trim(),
  uv: execFileSync('uv', ['--version'], { encoding: 'utf8' }).trim(),
  chromium: execFileSync('chromium', ['--version'], { encoding: 'utf8' }).trim(),
  runtime: runtimePackage.dependencies,
  plugins: profilePackage.dependencies,
};
mkdirSync('/opt/dsh-image', { recursive: true });
writeFileSync('/opt/dsh-image/versions.json', JSON.stringify(versions, null, 2) + '\n');
