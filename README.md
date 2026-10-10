# senior-dephx

**Make your AI agent think like a senior engineer.**

Your agent writes plausible code faster than you can review it. This makes it stop and
think first: research what already exists before adding another way to do it, name what
the change might break, ask you about the decisions that are actually yours, and refuse to
say "done" until it has watched the thing run.

Works in **Claude Code**, **OpenCode**, and **Codex**. MIT.

---

## The problem it solves

The code compiles. The tests pass. The agent says it's done.

Then the PR comes back covered in comments, or worse, it merges — and the bug shows up in
production three weeks later, in a part of the system nobody connected to that change.

The agent wasn't wrong about syntax. It was wrong about *everything around* the syntax: it
didn't know a helper for this already existed, didn't notice what else reads that column,
didn't ask which of two behaviours you actually wanted, and didn't check that its fix
worked before telling you it did.

## What "senior" actually means here

Not more syntax. Not a bigger model. **Procedure.**

A senior engineer isn't faster at typing — they're doing different things *before* and
*after* the typing:

- grep for prior art before writing a fifth variant of something that exists
- trace who else touches this table, contract, or component
- name the pattern (idempotency key, state machine, single source of truth) instead of
  hand-rolling correctness
- stop and ask on the real fork, with options and a recommendation
- run it, exercise the path, and read the output before claiming anything

That's all learnable and all mechanical. It's also exactly what an agent skips by default.
This plugin makes it the default instead.

## Quickstart

**Claude Code**

```
/plugin marketplace add ephraimd/senior-dephx
/plugin install senior-dephx
```

**OpenCode** — add to the `plugin` array in `~/.config/opencode/opencode.jsonc`:

```jsonc
"plugin": ["senior-dephx@git+https://github.com/ephraimd/senior-dephx.git"]
```

**Codex** installs it as a plugin, from the same marketplace:

```sh
codex plugin marketplace add ephraimd/senior-dephx
codex plugin add senior-dephx@senior-dephx
```

Codex runs a plugin's hooks only once you have trusted them, so approve senior-dephx's
SessionStart hook when Codex asks: that hook is what loads the gate. See
[A note on Codex](#a-note-on-codex) for a Codex without plugin support.

That's it. No config, no per-project setup.

## What changes

**Before:**

> *"I've added the refund handler. It builds and the tests pass."*

**After:**

> **Blast radius:** systemic — money, and a user can't undo it.
> **Prior art:** the sale path already credits the seller in `purchase_service`. I read it
> first: it credits the **net**. This handler was about to claw back the **gross**.
> **Side effects:** the reserve query and the affiliate payout both read the same column.
> **Pattern:** advisory lock + re-read inside the transaction (the codebase already does
> this in two other money paths — I'm matching them, not inventing a third).
> **Open fork:** on a lapsed deadline, should this auto-refund or escalate to a human?
> Auto is faster; escalate means every debit is a decision someone made. **I'd escalate.**

Same model. Same task. The difference is that it read the other side of the boundary before
changing this side — and it told you the one thing only you could decide.

A useful side effect: you can watch it reason. The brief is a senior's thinking, made
visible, on your codebase and your ticket.

## Real failures this catches

Every one of these is real. Every one passed a build. Most passed tests. None are exotic:

- **A refund clawed back the gross amount while the sale had credited the net.** Short by
  exactly the platform fee, so it could never succeed — it retried every hour for six days,
  alerting an admin each time. Found by reading the *credit* path before touching the
  *refund* path.
- **A column held the settlement currency on one code path and the buyer's currency on
  another.** Reading it directly looked obviously right, and would have under-debited by
  the exchange rate — silently, and only for some orders.
- **A setting was displayed to every customer and enforced nowhere.** A merchant
  advertising a 30-day return window had customers turned away on day 8.
- **A migration was written to run once and would have re-run on every boot,** quietly
  overwriting real users' choices. Caught by running it twice, which took ten seconds.
- **A background worker started in the API process,** so it ran once per replica instead of
  once, racing itself.

Not one of these was found by being clever. They were found by reading the other side of a
boundary, and by running the thing instead of trusting that it built.

## What's in it

| Skill | Fires when |
|---|---|
| **`software-engineer-intuition`** | Before anything non-trivial. The gate: calibrate blast radius → research prior art → trace side effects → name the pattern → post a Change Brief → ask on the forks. |
| **`code-comprehension`** | Before editing, refactoring or debugging code that already exists. Trace the real path, check a function is reachable before touching it, learn why each part is there, and verify every fact the change rests on by reading the source. Your memory of the code is not evidence. |
| **`engineering-standards`** | Writing or reviewing code. Reuse before adding (the same shape written twice, a dependency for what the project already does, a change bigger than the problem, a file grown past its one job), contract programming, fitting the existing structure, isolating vendors, typed errors, idempotency, snapshot-at-write, the simplest thing that works, knowing what the code costs to run, and not writing AI-looking code. |
| **`backend-shape`** | Designing or bootstrapping a backend, adding a feature, deciding where code goes. Composition readable in one place, dependencies handed in rather than reached for, organise by feature not layer, typed boundaries, config read once. In an existing codebase **that codebase's shape wins** — this fires only when the choice is genuinely yours. |
| **`ui-craft`** | Any UI work. De-slopping, primitive reuse, density above the fold, mobile-first, accent consistency, self-documenting controls. |
| **`verify-for-real`** | Before claiming anything works. A build is not a verification. |
| **`reviewing-for-scale`** | Reviewing a change or plan for whether it survives production scale, not whether it works. Indexability, the hidden count query, cost at N tenants, payload width, duplicated logic that drifts, tenant scope, unbounded inputs. The lens an "it's tested and it works" pass skips. |
| **`reviewing-for-ux`** | Reviewing a change or plan that touches a user-facing surface, for whether it survives the user it will have — one who was never trained. Day-30 discoverability, the zero-data first screen, consistency with the app's existing pattern, layman labels, destructive friction proportional to blast radius, hierarchy, and ranking experience findings by user impact instead of filing them under "product polish". |
| **`git-discipline`** | Before the first `git add`. Explicit-path staging, branch flow, history safety, attribution. |
| **`go-backend-blueprint`** | **Explicit invocation only — never on the agent's own initiative.** One person's house style for a Go backend, greenfield or full refactor. [See below](#blueprints). |

Plus a **gate** that stays resident, so the thinking applies without anyone remembering to
ask for it. The full procedure loads only when the work is big enough to need it — a typo
fix gets none of this, because process on a typo is its own kind of slop.

## Blueprints

Every other skill here is universal: it holds in any stack, and the agent learns your
project's vocabulary by reading your repo. **A blueprint is the one thing that isn't.**

`go-backend-blueprint` is one person's opinionated house style for a Go backend, written
down from services that already run in production: Gin and GORM, concrete enough to build
a service from, down to the file names. Layout and naming, composition and graceful
shutdown, background workers, the HTTP layer with its single response envelope and error
contract, the data layer and its migrations, and inter-service clients: roughly 4,300 lines
across an index and six reference files, read one at a time as you reach that layer.

It has **two modes and no third**: *greenfield* (build a new service to this standard) and
*full refactor* (bring an existing one to it). "Apply a bit of it while I'm in here" leaves
a service wearing two shapes, which is worse than either alone — now every reader has to
work out which half they're standing in.

### Why it loads only when you ask for it by name

This is the part worth being honest about. Every other skill here is defensible to a
stranger: reuse your primitives, verify before claiming done, don't put a storage type on
the wire. Those are arguments you can win. **A blueprint is taste.** Another Go shop could
reject every line of it and still be building the right thing. What it offers isn't
correctness, it's coherence — one set of answers that fit each other.

So auto-loading it would do the exact thing `backend-shape` and `engineering-standards`
exist to prevent: impose one person's house style on a repo whose own shape wins. It would
violate the plugin's own doctrine on the way in, which is the worst failure available here —
worse than any bug the standard prevents, because it costs the trust that lets any of these
skills run at all.

Gating it resolves that, and the resolution is the authority ladder: **human > project >
plugin.** "Fit what's there" is the right default *precisely because nobody asked*.
**Invoking the blueprint by name is the human asking** — and that's what authorises it to
override the deference every other skill obeys. Unasked, there's no human in that ladder at
all; there's only a plugin quietly rewriting someone's service to a stranger's taste.

Ask for it by name, literally:

> *"Use the go-backend-blueprint to build this service."*
> *"Refactor this service to the go-backend-blueprint."*

`test/smoke.sh` holds the gate to the extent a test can: an ungated blueprint — one whose
description doesn't say it loads only on request — fails the suite. That checks the rule is
stated, not that a model obeys it. Same limit as everything else here (see above), and the
reason the rule is stated where the model actually reads it.

## What it does not do

- **It doesn't make the model smarter.** It changes what the model does before and after
  writing code. That's a real difference, and a limited one.
- **It doesn't replace review.** It makes the agent's reasoning reviewable, which is not
  the same thing.
- **It won't stop your agent being wrong.** It makes wrong show up earlier — in a brief you
  can argue with, rather than in a merge.
- **Nothing is mechanically enforced.** These are instructions, not a linter. A model can
  ignore them. Fewer do when the rules are specific and the reason is stated.
- **It adds friction, on purpose, in proportion.** Systemic changes get a brief and a
  question. Trivial ones get nothing.

## The design rule

**These skills name no framework, no component, and no colour — deliberately.**

A portable skill that arrives carrying another project's nouns ("the primary button is the
indigo gradient", "don't collide with the bottom nav") is *exactly* the slop it exists to
prevent: technically correct, wrong context, no respect for the system's boundaries. It
would violate its own doctrine on install.

So every rule here is **structural, not nominal**:

> not *"import `Button` from `components/ui`"*
> but **"one canonical primary action — a second 'primary' style is drift, not a variant.
> Find yours; if there isn't one, that's a finding."**

The agent **discovers** your project's vocabulary by reading your repo, then holds it to
these rules. That's not a workaround; it's what the gate already demands: *questions 1–3
are answered by reading the codebase, never by asking the human.*

Your project's own rules (`AGENTS.md`, `CLAUDE.md`, its own skills) stay where they are and
**win on facts**. This plugin wins on procedure. **You win over both** — if your
instruction and any default disagree, the default loses, out loud.

## A note on `superpowers`

**This plugin stands alone.** Install nothing alongside it and every rule above still
holds. It also sits well next to the `superpowers` plugin, and is probably better with it.

The two are adjacent, not overlapping. Nothing here is suppressed when that plugin is
present, and nothing there is restated here. Where they touch, the split is one line:
**superpowers owns the procedure; this plugin owns the judgment and the policy.**

- `verification-before-completion` owns the law that you may not claim done without fresh
  evidence. `verify-for-real` owns *what* to exercise: a build is not a verification, run
  the migration twice, don't trust a control plane's success field.
- `brainstorming` and `systematic-debugging` own the procedure for designing and for
  debugging. `software-engineer-intuition` owns the judgment the gate demands: blast
  radius, prior art, what breaks.
- `finishing-a-development-branch` and `using-git-worktrees` own the procedure for landing
  work. `git-discipline` owns the policy that constrains it, and policy outranks procedure
  where they touch.

`engineering-standards`, `ui-craft`, and the rest have no counterpart there.

Claude Code and OpenCode **detect it at runtime** and say this only when it is genuinely
installed. The `AGENTS.md` install has no runtime to detect anything with, so it gets the
same text under an "if it's installed" sentence. Either way, you're never pointed at a skill that isn't there.

## A note on Codex

Codex reads this repo's Claude Code marketplace as it is, and the plugin works the same way
there: the skills load from it, and its SessionStart hook injects the gate. Codex runs a
plugin hook only after you trust it, and records that trust in `~/.codex/config.toml` under
`[hooks.state]`. To update:

```sh
codex plugin marketplace upgrade senior-dephx && codex plugin add senior-dephx@senior-dephx
```

**Without plugin support**, `install.sh --codex` is the fallback: it writes the gate into
`~/.codex/AGENTS.md`, always on, plus a pointer to each skill's file. Run it from a clone you
keep, because those pointers are absolute paths into it. Use one install or the other, not
both: with the plugin's hook trusted, the `AGENTS.md` block loads the gate a second time.

The installer is idempotent and only rewrites its own delimited block, so the rest of your
`AGENTS.md` survives.

## Making it yours

Fork it. Delete what you disagree with. The point isn't that these are the only good rules
— it's that your rules should live in one place and travel with you, instead of being
re-typed into every project until five slightly different versions of your judgment exist
and the differences are accidents.

If you add a skill, the bar is one question: **would this still be true in a project with a
different stack, a different product, and a different team?**

- **Yes** → strip the nouns, keep the teeth.
- **The principle travels but the example doesn't** → rewrite it structurally.
- **No** → leave it in that project. Per-project skills that know local facts are *supposed*
  to exist; this plugin explicitly defers to them.

Keep it sharp. "Reuse your primitives" is advice. "Reused twice → extract it, and a second
'primary' style is a bug to report" is a standard. Only one of those changes what an agent
does.

### Adding a blueprint

More languages are intended. A blueprint is the one place this plugin relaxes its own design
rule, so what it must satisfy is narrow and non-negotiable. `test/smoke.sh` enforces all four
— a blueprint that breaks any of them turns the suite red rather than shipping quietly.

- **It lives at `skills/<lang>-backend-blueprint/`.** Skill discovery is a flat glob over
  `skills/*/`, so a tidier-looking `skills/stacks/<lang>/` is never found: the glob matches
  the `stacks` folder, not the blueprint inside it. The skill is loaded nowhere and advertised
  to Codex nowhere.
- **Its description gates it inside the first 150 characters.** The Codex `AGENTS.md` block
  renders every description cut at exactly 150 chars (`${desc:0:150}…`), and for anyone on
  that install the block is the only description Codex sees. A gate clause after that point isn't merely missed: Codex
  advertises the blueprint with its gate sliced off, which is worse than not shipping it.
- **Its description states the do-not-autoload rule** — not just when to use it, but that it
  must never load for general work in that language, for another language, or on the agent's
  own initiative.
- **It may name its language and its libraries. It may never name a company, product, repo,
  or host.** The first half is the exemption that makes a blueprint possible: it can't be
  concrete without naming things. The second half is where the exemption stops. A house style
  arriving with an employer's nouns in it is just someone else's codebase in your repo — the
  slop the design rule above exists to keep out, wearing a better suit.

## Layout

```
core/GATE.md                      one gate, three consumers
core/SUPERPOWERS.md               the deference map, emitted only when superpowers is there
skills/*/SKILL.md                 the doctrine
skills/*-backend-blueprint/
  references/                     the concrete patterns, one file per layer, read on demand
hooks/                            Claude Code SessionStart injection
.opencode/plugins/                OpenCode: skills path + gate injection
codex/                            why Codex is different
install.sh                        wires all three
test/smoke.sh                     the design rules, executable: the blueprint gate, the
                                  no-nouns rule, all three install paths, and proof the
                                  installer never damages a file it doesn't own
```

Three copies of the same judgment would drift — the exact failure this exists to end. So
there is one `GATE.md`, consumed three ways.

## License

MIT. Use it, fork it, sell what you build with it.

## UI contract preservation

UI work loads the existing `ui-craft` and `reviewing-for-ux` skills and the consuming
project's canonical standards before planning or review. The startup gate carries that
requirement across supported adapters. Fresh sessions and subagents discover current
sources, apply project requirements and report observed evidence. Reusable policy covers
stable workspaces, growing lists, dialog containers, action states, ownership and scoped
metrics. Product copy, branding, tokens, paths and specific workflows stay in the project.

Run `bash test/smoke.sh` and `bash test/ui-policy.sh` before releasing. Static checks prove
policy wiring, not model compliance. `test/ui-pressure-scenarios.md` defines independent
agent exercises for that behavior and their evidence requirements.
