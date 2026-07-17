# Porting Portable Judgment Into senior-dephx — Design

- **Date:** 2026-07-02
- **Status:** Approved design — pending implementation plan
- **Branch:** `feat/portable-judgment-port`
- **Target version:** 0.2.0

## 1. Context

The doctrine here was written from scratch. In parallel, a production Go/JVM backend
accumulated ~10 project-level skills carrying the same author's judgment in that project's
nouns. An audit extracted **74 portable kernels** — ~29 already covered here, ~54 "new."

**Porting all 54 was wrong, and the first draft of this spec was wrong to propose it.**
Applying the correct filter (§3) collapses 54 to about five. This document is the reduced
scope.

## 2. Goals / non-goals

**Goals**
- Ship the **preferences** — the only thing a model cannot supply for itself.
- Ship the handful of rules where a model's **default is actively wrong**, not merely
  unthought.
- Fix one **live contradiction** in the existing doctrine.
- Make the **design rule executable** rather than aspirational.
- Serve Go and lightweight-JVM backends specifically, **extensibly** (more languages later,
  zero core churn), without the core naming a language.

**Non-goals**
- Porting **facts**. See §3.
- `integration-instinct`, `external-systems`, or the 22-rule `engineering-standards`
  absorption proposed in the first draft. All withdrawn.
- Generalising project-local facts (vendor consoles, hosts, table names, helper signatures,
  directory naming). They stay in the project, where the plugin already defers to them.
- Replacing `superpowers`.

## 3. The filter (why this shrank from 54 to ~5)

The wrong test was *"would this bite a stranger?"* — every true statement about software
passes it. The right test is:

> **Is this a *fact the model already has*, or a *choice where you have a side*?**

- **Facts** — constant-time compare, UTC vs. calendar semantics, at-least-once dedupe,
  async-after-commit, absent-vs-zero, retry + dead-letter, tenant scoping, mass assignment.
  A capable model **already knows every one.** It doesn't fail to know them; it fails to
  **stop and apply** them — which is precisely what the gate already forces. Writing them
  down hands a lookup table to something that already has one. **Marginal. Do not ship.**
- **Preferences** — *no framework by default*, *the entrypoint is the composition root*,
  *no container / annotations / reflection*, *organise by feature not layer*, *one interface
  per axis of change*. These are **contested** — half the industry runs the opposite and has
  good reasons. **A model cannot infer your side.** Only you can supply it. **This is the
  entire value.**
- **Wrong-default** — a narrow third class: the model's *unprompted behaviour* is actively
  incorrect, not just unconsidered. Worth stating even though it's "knowledge."

Everything below is preference or wrong-default. Nothing else ships.

## 4. The distillation (the soul)

The Go and JVM opinions are **not two sets of rules. They are one conviction with two
accents:**

> **Explicit over magic.** You should be able to read the whole dependency graph in one
> file. The entrypoint is where everything is constructed. A framework is a decision to
> surface, not a default.

*No Spring · no DI container · no annotations · no reflection · no classpath scanning · no
`init()` · no package-level singletons · no framework-by-default* — every one of those is
that single belief, wearing a language's clothes.

**Therefore: the conviction goes in the core (language-free). Only the accent goes in a
pack.** This is what keeps the core universal while the packs stay thin.

## 5. What ships

### 5.1 `skills/backend-shape/` — NEW (universal, names no language)
The files/folders/code philosophy. Trigger: **designing or bootstrapping a backend service
or component where the shape is your call.**

- **Organise by feature, not by layer.** A feature owns its transport, its decisions, and
  its data access together. Layer-folders scatter one change across three directories and
  make a feature's blast radius invisible.
- **Each layer does only its job.** Transport parses, validates, delegates — it decides
  nothing. Logic decides — it knows no transport and writes no queries. Data queries — it
  holds no policy.
- **Typed DTOs at every boundary; never the storage model on the wire.** They change for
  different reasons — couple them and a column rename becomes an API break.
- **The entrypoint is the composition root.** Construct everything explicitly, in one place,
  and pass it in. You should read the whole dependency graph in one file. No container, no
  annotations, no reflection, no package-level singletons. *(the soul)*
- **A framework is a decision to surface, not a default.** Reach for the smallest thing that
  does the job.
- **Config is read once, at startup, into a typed value.** Missing required config crashes
  at boot; optional gets an explicit default. Never read the environment from inside a call
  path.
- **One interface per axis of change, not per class.** Abstract what varies; leave the rest
  concrete.

**Deference (load-bearing):** in an existing codebase **its shape wins** —
`engineering-standards` §1 ("fit the existing structure") outranks this skill. This is for
when the choice is *actually yours*: greenfield, a new service, or a project with no answer.
Stated in the skill body so it can never be read as "restructure their repo."

### 5.2 `skills/go-service-shape/` — NEW (pack, description-gated)
Only the accent:
- **The stdlib and a thin router before a web framework.**
- **No `init()` magic, no package-level singletons** — construct in `main`.
- **An `Impl` suffix is fine when the interface owns the name and there is exactly one.** It
  stops being fine at two.
- The feature folder holds its transport, logic, data access, and its DTOs together.

### 5.3 `skills/java-service-shape/` — NEW (pack, description-gated)
Only the accent:
- **No Spring.** A headless worker or a thin HTTP surface needs a `main()`, a router, and a
  client — not a container, a classpath scan, and an annotation dialect.
- **One artifact: `application` + a shadow fat jar**, `exec java -jar` as PID 1.
- **`main()` is the composition root** — constructor wiring; no annotations, no reflection,
  no classpath scanning.
- **Name implementations for what they do, not `Impl`.** That convention disambiguates a
  single implementation and becomes noise at three — the *reason* doesn't transfer from Go,
  so neither should the tic.

### 5.4 The wrong-default rules (~5)
Only where the model's unprompted behaviour is incorrect:

| Rule | Home | Why it ships |
|---|---|---|
| **Replace-vs-merge: determine which before *any* external save/update call.** Assuming merge on a replace endpoint silently deletes everything you didn't send. Read-modify-write — and read first. | `engineering-standards` §3 | Models genuinely assume merge and wipe config |
| **A business "no" is a success.** Three outcomes: success, retryable, poison. "The card was declined" is a *result* — record it and ack. | `engineering-standards` §4 | Models genuinely retry business failures forever |
| **Enumerate what a provider does *not* emit.** Every un-evented mutation needs a poll. Push + reconcile, never push alone. | `engineering-standards` §3 | Models genuinely assume webhook coverage is complete |
| **A control plane's success field means "accepted," not "live."** Verify the resulting artifact's identity, not the status code. | `verify-for-real` | Models genuinely trust `status: done` |
| **A green build with a failed deploy is configuration, not code.** Changing code first destroys the evidence and adds a variable. | `verify-for-real` | Models genuinely edit code first |

### 5.5 `core/GATE.md` — 1 edit
Resolve the **live contradiction**: the gate says *"One consolidated round, not a drip"*;
`software-engineer-intuition` Step 4 repeats it; the source corpus's interviewing skill says
*"one question at a time."* They conflict today.

> **Consolidated round for *independent* forks. One at a time only when the answers are
> *dependent*** — when a later question's content changes based on an earlier answer (a
> design tree). Never a drip of independent questions.

No other gate change. It is the only always-on surface and stays brutal.

### 5.6 Verification — `test/smoke.sh` + a nouns check
The plugin preaches *"a build is not a verification"* and cannot verify itself. Close it:

1. **Claude** — manifests parse; every `skills/*/SKILL.md` has valid frontmatter with a
   non-empty `name` + `description`; `hooks/hooks.json` parses; the hook is executable and
   emits the gate.
2. **OpenCode** — the plugin module imports; `config()` appends the skills path; the
   transform injects **exactly once** and is idempotent on re-entry.
3. **Codex** — `install.sh --codex --here` into a temp dir writes the block; **running it
   twice yields an identical file** and preserves surrounding content.
4. **Nouns check** — grep `core/` and every `skills/*/` **except `*-service-shape/`** for a
   denylist of framework/vendor tokens, **word-boundaried** (an un-anchored grep flags
   "plu*gin*" and "en*gin*eering" and a noisy check gets ignored — an ignored check is worse
   than none). Packs are exempt from the *language* denylist (naming Go is their job) but
   **not** from the *project*-noun denylist: a pack naming a company's helper, table, or
   host has become a project skill wearing a language's name.

This makes the design rule **executable**. It is the highest-leverage test in the repo.

### 5.7 README + manifests
- **Stack packs** — what they are, that the description *is* the isolation, and the
  contract for adding a language: one `skills/<language>-service-shape/` directory, **zero
  core changes**.
- **superpowers** — works alone; sharper together. Where each wins.
- Version → **0.2.0**.

## 6. Skill layout — flat, not nested

All three consumers discover skills **one level deep** (`install.sh` globs `skills/*/`). A
`skills/stacks/<lang>/` layout would be silently omitted from the Codex block. The directory
was never the isolation mechanism — **the description is.**

**Naming convention:** `<language>-service-shape`. The nouns check keys off it.

## 7. Interop with `superpowers`

Skills are static markdown and cannot self-disable. The only surface with runtime knowledge
is the **gate injection**, which already exists as three thin adapters over one `GATE.md`:
`hooks/session-start.sh`, `.opencode/plugins/senior-dephx.js`, `install.sh --codex`.

Each detects superpowers and, if present, appends one routing line to the injected gate
(e.g. *"for generic debugging use `superpowers:systematic-debugging`; for spec-shaped design
use `superpowers:brainstorming`"*). Correctness must **never depend on detection** — the
plugin works standalone; detection only sharpens routing.

## 8. What is explicitly NOT ported

- All project-local facts. They stay. The audit's verdict: *"they are the right kind of
  local."*
- Every rule in the "facts" class (§3) — the model has them and the gate makes it use them.
- The interviewing skill: ~75% already in the gate; the novel half is
  `superpowers:brainstorming`'s job.
- Rules that assume a microservice fleet with a broker (kill-switches across N consumers,
  producer boot-order, never-create-the-stream, shared-DB deploy ordering). **That is one
  architecture, not portable judgment.**

## 9. Rollout

1. Gate cadence fix (1 edit).
2. `backend-shape` — the centrepiece.
3. The two packs.
4. The five wrong-default rules into `engineering-standards` / `verify-for-real`.
5. superpowers detection + static deference notes.
6. `test/smoke.sh` + the nouns check.
7. README + version 0.2.0.

## 10. Risks

- **`backend-shape` reads as "restructure their repo."** Mitigated by the §5.1 deference
  clause: the existing codebase's shape always wins; this fires only when the choice is
  yours.
- **A pack leaks project nouns** — becomes a project skill wearing a language's name.
  Mitigated by the nouns check covering packs for *project* nouns.
- **Wording softens.** Preferences stated softly read as suggestions and change nothing. One
  line, with teeth, or it doesn't ship.
- **Scope creeps back.** The §3 filter is the control. If a proposed rule is something the
  model already knows, it does not ship — no matter how true it is.
