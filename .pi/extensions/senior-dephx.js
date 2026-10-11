import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const extensionPath = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionPath), '../..');
const marker = '<SENIOR-DEPHX-GATE>';

// Pi npm packages live beside its git packages, not in their module lookup chain.
// Use the public pi-subagents API when available; never edit role defaults or tools.
async function childExtensionRegistry(cwd) {
  const agentDir = process.env.PI_CODING_AGENT_DIR || join(homedir(), '.pi/agent');
  for (const anchor of [import.meta.url, join(agentDir, 'npm/package.json'), join(cwd, 'package.json')]) {
    const require = createRequire(anchor);
    let entry;
    try { entry = require.resolve('pi-subagents/required-child-extensions'); }
    catch (error) {
      if (error.code === 'MODULE_NOT_FOUND') continue;
      throw error;
    }
    // Some pi-subagents releases export TypeScript from node_modules. Native Node
    // imports cannot strip those types. Reuse that package's own Jiti dependency.
    if (entry.endsWith('.ts')) {
      const { createJiti } = createRequire(entry)('jiti');
      return createJiti(import.meta.url, { moduleCache: false }).import(entry);
    }
    return import(pathToFileURL(entry).href);
  }
  return undefined;
}

export default function seniorDephxPi(pi) {
  const gate = readFileSync(join(root, 'core/GATE.md'), 'utf8');
  let registration;
  let childWarning = '';

  pi.on('session_start', async (_event, ctx) => {
    registration?.dispose();
    registration = undefined;
    childWarning = '';
    try {
      const api = await childExtensionRegistry(ctx.cwd);
      if (api) registration = api.registerRequiredChildExtensions({
        sessionId: ctx.sessionManager.getSessionId(),
        extensions: [{ id: 'senior-dephx', path: extensionPath }],
      });
    } catch (error) {
      childWarning = `Pi child policy registration failed: ${error.message}. Before delegating, require the child to read ${join(root, 'core/GATE.md')} and the applicable skills independently. Automatic child loading is unverified.`;
      ctx.ui?.notify(childWarning, 'warning');
    }
  });

  pi.on('session_shutdown', async () => {
    registration?.dispose();
    registration = undefined;
  });

  // Applied to each turn's base prompt, so compaction cannot lose the gate.
  // It preserves all existing instructions and writes no repository or settings files.
  pi.on('before_agent_start', async (event) => {
    if (event.systemPrompt.includes(marker)) return;
    return { systemPrompt: `${event.systemPrompt}\n\n${marker}\n
Before reviewing, planning or changing UI, use \`read\` on both exact paths below.
Read these files yourself; they are not preloaded by this gate. A parent's summary
or a copy of the project rules does not replace loading these skills:
- ${join(root, 'skills/ui-craft/SKILL.md')}
- ${join(root, 'skills/reviewing-for-ux/SKILL.md')}

Every UI subagent handoff includes these two skill paths as well as the consuming
project's canonical paths, version, constraints and acceptance scenarios. Each child
loads them independently and names the files it read in its return. This applies to
read-only UI reviews and plans as well as implementation.

${gate}\n
## Pi skill loading

Use Pi's \`read\` tool to load the relevant \`SKILL.md\` from ${join(root, 'skills')}. Skills are discovered from this package in parent sessions. A child with a restricted skills catalog can read the same files directly; do not invent a \`Skill\` tool.

Before UI work, independently read \`ui-craft/SKILL.md\`, \`reviewing-for-ux/SKILL.md\`, and the consuming project's current canonical standards. For authorized UI implementation, \`ui-craft/references/repository-guardrails.md\` owns adapting repository guardrails. For other non-trivial work, read \`software-engineer-intuition/SKILL.md\`. Load \`go-backend-blueprint\` only when the human asks for it by name; installing this package does not authorize a Go refactor.

Use the available native \`subagent\` tool only when delegation is authorized. Every UI child independently reads the paths, versions and constraints in its handoff and returns evidence and limitations. Preserve tool and capability limits; external runners need their own installation and verification.
${childWarning}\n</SENIOR-DEPHX-GATE>` };
  });
}
