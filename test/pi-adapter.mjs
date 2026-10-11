import assert from 'node:assert/strict';
import { mkdtempSync, cpSync, mkdirSync, readFileSync, writeFileSync, readdirSync, rmSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));

test('Pi discovers the native gate and the canonical skills from the package manifest', () => {
  assert.deepEqual(manifest.pi, { extensions: ['./.pi/extensions/senior-dephx.js'], skills: ['./skills'] });
});

test('Pi loads policy without repository writes, preserves other prompt content, and does not duplicate it', async () => {
  assert.ok(manifest.pi?.extensions?.length, 'The package does not register a Pi startup gate');
  const fixture = mkdtempSync(join(tmpdir(), 'dephx-pi-'));
  try {
    cpSync(join(root, '.pi'), join(fixture, '.pi'), { recursive: true });
    cpSync(join(root, 'core'), join(fixture, 'core'), { recursive: true });
    cpSync(join(root, 'package.json'), join(fixture, 'package.json'));
    mkdirSync(join(fixture, 'repo'));
    const { default: extension } = await import(pathToFileURL(join(fixture, manifest.pi.extensions[0])));
    const hooks = new Map();
    await extension({ on: (name, handler) => hooks.set(name, handler) });
    const ctx = { cwd: join(fixture, 'repo') };
    const turn = hooks.get('before_agent_start');
    assert.equal(typeof turn, 'function');
    const first = await turn({ systemPrompt: 'Existing project rules.\nOther plugin policy.' }, ctx);
    assert.ok(first.systemPrompt.startsWith('Existing project rules.\nOther plugin policy.'));
    assert.ok(first.systemPrompt.includes(readFileSync(join(root, 'core/GATE.md'), 'utf8')));
    assert.ok(first.systemPrompt.includes('repository-guardrails.md'));
    assert.ok(first.systemPrompt.includes('go-backend-blueprint'));
    assert.ok(first.systemPrompt.includes(join(fixture, 'skills')));
    assert.ok(first.systemPrompt.includes(join(fixture, 'skills/ui-craft/SKILL.md')));
    assert.ok(first.systemPrompt.includes(join(fixture, 'skills/reviewing-for-ux/SKILL.md')));
    assert.ok(first.systemPrompt.indexOf('Read these files yourself') < first.systemPrompt.indexOf('# The Gate'));
    const second = await turn({ systemPrompt: first.systemPrompt }, ctx);
    assert.equal(second, undefined, 'Already injected policy must not grow on every turn');
    const afterCompact = await turn({ systemPrompt: 'Compacted base prompt.' }, ctx);
    assert.ok(afterCompact.systemPrompt.includes('SENIOR-DEPHX-GATE'));
    assert.deepEqual(readdirSync(ctx.cwd), [], 'Loading policy must not bootstrap repository files');
  } finally { rmSync(fixture, { recursive: true, force: true }); }
});

test('Pi registers its gate for foreground and background children, disposes on switch and shutdown', async () => {
  const fixture = realpathSync(mkdtempSync(join(tmpdir(), 'dephx-pi-child-')));
  const previousDir = process.env.PI_CODING_AGENT_DIR;
  try {
    cpSync(join(root, '.pi'), join(fixture, '.pi'), { recursive: true });
    cpSync(join(root, 'core'), join(fixture, 'core'), { recursive: true });
    cpSync(join(root, 'package.json'), join(fixture, 'package.json'));
    const pkg = join(fixture, 'agent/npm/node_modules/pi-subagents');
    mkdirSync(pkg, { recursive: true });
    writeFileSync(join(pkg, 'package.json'), JSON.stringify({ type: 'module', exports: { './required-child-extensions': './registry.js' } }));
    // Boundary double: exercise the real adapter's module resolution and lifecycle.
    // Actual child launch semantics are tested separately in native Pi sessions.
    writeFileSync(join(pkg, 'registry.js'), `export const active = new Map();
      export function registerRequiredChildExtensions(value) {
        if (active.has(value.sessionId)) throw new Error('peer registration already exists');
        active.set(value.sessionId, value.extensions);
        return { dispose() { active.delete(value.sessionId); } };
      }`);
    process.env.PI_CODING_AGENT_DIR = join(fixture, 'agent');
    const { default: extension } = await import(pathToFileURL(join(fixture, manifest.pi.extensions[0])));
    const registry = await import(pathToFileURL(join(pkg, 'registry.js')));
    const hooks = new Map();
    await extension({ on: (name, handler) => hooks.set(name, handler) });
    const context = (id) => ({ cwd: fixture, sessionManager: { getSessionId: () => id }, ui: { notify: () => {} } });
    await hooks.get('session_start')({}, context('first'));
    assert.deepEqual(registry.active.get('first'), [{ id: 'senior-dephx', path: join(fixture, '.pi/extensions/senior-dephx.js') }]);
    await hooks.get('session_start')({}, context('second'));
    assert.equal(registry.active.has('first'), false);
    assert.equal(registry.active.has('second'), true);
    await hooks.get('session_shutdown')();
    await hooks.get('session_shutdown')();
    assert.equal(registry.active.size, 0);
    registry.active.set('peer', [{ id: 'peer', path: 'preserve' }]);
    const warnings = [];
    await hooks.get('session_start')({}, { ...context('peer'), ui: { notify: (message) => warnings.push(message) } });
    assert.deepEqual(registry.active.get('peer'), [{ id: 'peer', path: 'preserve' }]);
    assert.match(warnings[0], /Automatic child loading is unverified/);
    const prompt = await hooks.get('before_agent_start')({ systemPrompt: 'Base' });
    assert.match(prompt.systemPrompt, /peer registration already exists/);
  } finally {
    if (previousDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousDir;
    rmSync(fixture, { recursive: true, force: true });
  }
});
