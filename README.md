# senior-dephx

**Engineering judgment as a plugin.** One source of how you think, installed into every
project and every tool, instead of re-created (and quietly drifted) in each one.

Most agent setups carry *knowledge* — this stack, that convention. This one carries
**decision procedure**: how to scope a change, what to research before writing, when to
stop and ask, and what "done" has to mean before you say it.

## What's in it

| Skill | Fires when |
|---|---|
| **`software-engineer-intuition`** | Before anything non-trivial. The gate: calibrate blast radius → research prior art → trace side effects → name the pattern → post a Change Brief → ask on the forks. |
| **`engineering-standards`** | Writing or reviewing code. Contract programming, fitting the existing structure, isolating vendors, typed errors, idempotency, snapshot-at-write, and not writing AI-looking code. |
| **`ui-craft`** | Any UI work. De-slopping, primitive reuse, density above the fold, mobile-first, accent consistency, self-documenting controls. |
| **`verify-for-real`** | Before claiming anything works. A build is not a verification. |
| **`git-discipline`** | Before the first `git add`. Explicit-path staging, branch flow, history safety, attribution. |

Plus a **gate** (`core/GATE.md`) that is always resident, so the thinking applies without
anyone remembering to invoke it. The full procedure loads on demand.

## The one design rule

**These skills name no framework, no component, and no colour — on purpose.**

A portable skill that arrives carrying another project's nouns ("the primary button is the
indigo→purple gradient", "Events are indigo") is *exactly* the slop it exists to prevent:
technically correct, wrong context, doesn't respect the system's boundaries. It would
violate its own doctrine on install.

So every rule here is **structural, not nominal**:

> not *"import `Button` from `components/ui`"*
> but **"one canonical primary action — a second 'primary' style is drift, not a variant.
> Find yours; if there isn't one, that's a finding."**

The agent **discovers** your project's vocabulary by reading your repo, then holds it to
these rules. That's not a workaround — it's what the gate already demands: *questions 1–3
are answered by reading the codebase, never by asking the human.*

Your project's own rules (`AGENTS.md`, `CLAUDE.md`, its own skills) stay where they are and
**win on facts**. This plugin wins on procedure. **You win over both** — if your instruction
and a default disagree, the default loses, out loud.

## Install

```sh
git clone https://github.com/ephraimd/senior-dephx.git
cd senior-dephx && ./install.sh          # prints what each tool needs
```

### Claude Code — native

```
/plugin marketplace add ephraimd/senior-dephx
/plugin install senior-dephx
```

Skills auto-load by `description`. A `SessionStart` hook keeps the gate resident, and
re-fires on `compact` — precisely when an agent starts forgetting how you wanted it to
work.

### OpenCode — native

Add to the `plugin` array in `~/.config/opencode/opencode.jsonc`:

```jsonc
"plugin": ["senior-dephx@git+https://github.com/ephraimd/senior-dephx.git"]
```

Registers its own skills directory (no symlinks), and injects the gate into the first user
message — a user message rather than a system one, so it isn't re-sent every turn.

### Codex — AGENTS.md only

```sh
./install.sh --codex          # ~/.codex/AGENTS.md  (global)
./install.sh --codex --here   # ./AGENTS.md         (this project)
```

**Codex has no plugin or skill system.** No `/skill`, no loading-by-description —
`AGENTS.md` is the entire extension surface. So Codex gets the gate always-on plus pointers
to the full skills, which is less than the other two get. Being straight about that beats
pretending parity.

The installer is idempotent and only rewrites its own delimited block; anything else in
your `AGENTS.md` survives.

## Adding skills from your other projects

The bar for entry is one question: **would this still be true in a project with a different
stack, a different product, and a different team?**

- **Yes** → it belongs here. Strip the nouns, keep the teeth.
- **No, but the *principle* underneath travels** → rewrite it structurally (see above) and
  bring the principle.
- **No** → leave it in that project. That's not a failure; per-project skills that know
  local facts are *supposed* to exist, and this plugin explicitly defers to them.

Keep the sharpness. A rule you can't act on is decoration — "reuse your primitives" is
advice; "reused twice → extract it, and a second 'primary' style is a bug to report" is a
standard.

## Layout

```
core/GATE.md                      one gate, three consumers
skills/*/SKILL.md                 the doctrine (name + description frontmatter)
hooks/                            Claude Code SessionStart injection
.opencode/plugins/senior-dephx.js OpenCode: skills path + gate injection
codex/                            why Codex is different
install.sh                        wires all three
```

Three copies of your judgment would drift — the exact failure this plugin exists to end.
So there is one `GATE.md`, consumed three ways.

## License

MIT.
