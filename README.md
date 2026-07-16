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

**Codex**

```sh
git clone https://github.com/ephraimd/senior-dephx.git
cd senior-dephx && ./install.sh --codex     # writes ~/.codex/AGENTS.md
```

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
| **`engineering-standards`** | Writing or reviewing code. Contract programming, fitting the existing structure, isolating vendors, typed errors, idempotency, snapshot-at-write, and not writing AI-looking code. |
| **`ui-craft`** | Any UI work. De-slopping, primitive reuse, density above the fold, mobile-first, accent consistency, self-documenting controls. |
| **`verify-for-real`** | Before claiming anything works. A build is not a verification. |
| **`git-discipline`** | Before the first `git add`. Explicit-path staging, branch flow, history safety, attribution. |

Plus a **gate** that stays resident, so the thinking applies without anyone remembering to
ask for it. The full procedure loads only when the work is big enough to need it — a typo
fix gets none of this, because process on a typo is its own kind of slop.

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

## A note on Codex

Codex has **no plugin or skill system**. `AGENTS.md` is the entire extension surface — no
`/skill`, no loading-by-description. So Codex gets the gate always-on plus pointers to the
full skills, which is less than Claude Code and OpenCode get.

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

## Layout

```
core/GATE.md                      one gate, three consumers
skills/*/SKILL.md                 the doctrine
hooks/                            Claude Code SessionStart injection
.opencode/plugins/                OpenCode: skills path + gate injection
codex/                            why Codex is different
install.sh                        wires all three
```

Three copies of the same judgment would drift — the exact failure this exists to end. So
there is one `GATE.md`, consumed three ways.

## License

MIT. Use it, fork it, sell what you build with it.
