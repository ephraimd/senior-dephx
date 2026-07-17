/**
 * senior-dephx for OpenCode.
 *
 * Does two things:
 *   1. Registers this plugin's skills directory so OpenCode's native `skill` tool
 *      discovers them. No symlinks, no per-project config edits.
 *   2. Injects the always-on gate into the first user message of each session, plus the
 *      deference map when the sibling `superpowers` plugin is detected alongside it.
 *
 * The gate is injected rather than left to on-demand loading because a thinking
 * discipline that only applies when someone remembers to invoke it is not a discipline.
 * Only the gate is resident; the full procedure lives in the software-engineer-intuition
 * skill and loads when it is actually needed.
 *
 * It goes into a user message rather than a system message deliberately: system messages
 * are re-sent every turn (token bloat), and multiple system messages break some models.
 */

import path from 'path';
import fs from 'fs';
import os from 'os';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const pluginRoot = path.resolve(__dirname, '..', '..');
const skillsDir = path.join(pluginRoot, 'skills');
const gatePath = path.join(pluginRoot, 'core', 'GATE.md');
const superPath = path.join(pluginRoot, 'core', 'SUPERPOWERS.md');

const MARKER = 'SENIOR-DEPHX-GATE';

// The sibling plugin counts as installed when its skills are actually reachable, which is
// the thing the fragment's pointers depend on - a config entry alone can be stale. Two of
// its skills are probed rather than one so a partial install still reads as present.
const SIBLING_SKILLS = ['verification-before-completion', 'brainstorming'];

const isDir = (p) => {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
};

// Best-effort by design, and it may never throw: it runs inside the gate's own injection
// path, so anything escaping here costs the gate itself - a far worse outcome than a
// missing deference note.
const siblingInstalled = (config) => {
  try {
    const roots = [
      ...(config?.skills?.paths ?? []),
      path.join(os.homedir(), '.config', 'opencode', 'skills'),
    ];
    if (roots.some((r) => typeof r === 'string' && SIBLING_SKILLS.some((s) => isDir(path.join(r, s))))) {
      return true;
    }
    const plugins = config?.plugin ?? [];
    return (
      Array.isArray(plugins) &&
      plugins.some((p) => typeof p === 'string' && p.includes('superpowers'))
    );
  } catch {
    return false;
  }
};

export const SeniorDephx = async () => {
  // The config hook hands us the live config; the transform hook is not given one, so the
  // reference is kept for detection to read later.
  let _config;

  // Read once. This hook fires on every agent step, not every turn, so re-reading from
  // disk here would mean a file read per step. The fragment rides inside the same MARKER
  // block as the gate, so the existing double-injection guard covers it for free.
  let _gate;
  const gate = () => {
    if (_gate !== undefined) return _gate;
    let sibling = '';
    try {
      if (siblingInstalled(_config) && fs.existsSync(superPath)) {
        sibling = `\n${fs.readFileSync(superPath, 'utf8')}\n`;
      }
    } catch {
      sibling = '';
    }
    _gate = fs.existsSync(gatePath)
      ? `<${MARKER}>\nYou are a senior engineer. This is how you think here.\n\n` +
        `${fs.readFileSync(gatePath, 'utf8')}\n` +
        `${sibling}` +
        `**Tool mapping:** use OpenCode's native \`skill\` tool to load the skills named ` +
        `above; \`todowrite\` for task tracking; @mention for subagents.\n</${MARKER}>`
      : null;
    return _gate;
  };

  return {
    // Modifications to the live config are visible when skills are lazily discovered
    // later, because Config.get() returns a cached singleton.
    config: async (config) => {
      _config = config;
      config.skills = config.skills || {};
      config.skills.paths = config.skills.paths || [];
      if (!config.skills.paths.includes(skillsDir)) {
        config.skills.paths.push(skillsDir);
      }
    },

    'experimental.chat.messages.transform': async (_input, output) => {
      const g = gate();
      if (!g || !output.messages?.length) return;

      const firstUser = output.messages.find((m) => m.info.role === 'user');
      if (!firstUser?.parts?.length) return;

      // OpenCode may pass an already-transformed array back through this hook; without
      // this guard the gate gets injected repeatedly into the same message.
      if (firstUser.parts.some((p) => p.type === 'text' && p.text?.includes(MARKER))) return;

      const ref = firstUser.parts[0];
      firstUser.parts.unshift({ ...ref, type: 'text', text: g });
    },
  };
};

export default SeniorDephx;
