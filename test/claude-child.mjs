import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
test('Claude injects the canonical gate directly into every native subagent', () => {
  const hooks = JSON.parse(readFileSync(`${root}/hooks/hooks.json`, 'utf8')).hooks;
  assert.equal(hooks.SubagentStart?.[0]?.matcher, '.*', 'No native child startup hook registered');
  const handler = hooks.SubagentStart[0].hooks[0];
  assert.equal(handler.command, '"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh" --subagent');
  assert.equal(handler.async, false);
  const run = spawnSync('bash', [`${root}/hooks/session-start.sh`, '--subagent'], {
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: root }, encoding: 'utf8',
    input: JSON.stringify({ hook_event_name: 'SubagentStart', agent_type: 'Explore' }),
  });
  assert.equal(run.status, 0, run.stderr);
  const out = JSON.parse(run.stdout).hookSpecificOutput;
  assert.equal(out.hookEventName, 'SubagentStart');
  assert.ok(out.additionalContext.includes(readFileSync(`${root}/core/GATE.md`, 'utf8')));
  assert.ok(out.additionalContext.includes(`${root}/skills`));
  assert.ok(out.additionalContext.includes('independently'));
});
