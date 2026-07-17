# Porting Portable Judgment Into senior-dephx — Design

- **Date:** 2026-07-02
- **Status:** Approved design — pending implementation plan
- **Branch:** `feat/portable-judgment-port`
- **Target version:** 0.2.0

## 1. Context

The doctrine here was written from scratch. In parallel, a production Go/JVM backend
accumulated ~10 project-level skills carrying the same author's judgment in that project's
nouns. An audit extracted **74 portable kernels** — ~29 already covered here, ~54 "new."

**Porting all 54 was wrong.** Applying the correct filter (§3) collapses it to about five.
This document is the reduced scope, plus the two things that *are* genuinely worth shipping:
a universal shape philosophy, and opinionated per-language blueprints behind explicit
invocation.

## 2. Goals / non-goals

**Goals**
- Ship the **preferences** — the only thing a model cannot supply for itself.
- Ship the few rules where a model's **default is actively wrong**, not merely unthought.
- Give the author's **opinionated house style** a home that travels, **without it ever
  applying unasked**.
- Fix one **live contradiction** in the existing doctrine.
- Make the **design rule executable** rather than aspirational — **partially**, and honestly
  so. A grep catches unambiguous nouns (`golang`, `jvm`, `gorm`) and English-word nouns
  (`Go`, `Spring`) in a *technology context* (*"use Spring"*, *"Go service"*, or inside a
  code span). It **cannot** catch a sentence-initial mention with an arbitrary verb
  (*"Spring handles that."*) — that needs `^`-anchoring, which flags this repo's own
  imperative voice (*"Go and find out"*), and the set of verbs after a proper noun is
  unbounded. **Grep loses that case; review must catch it.** A branch that closed it on paper
  would make the check *look* complete — the exact false confidence this plugin exists to
  prevent. State the gap; never imply coverage you don't have.

**Non-goals**
- Porting **facts** (§3).
- `integration-instinct`, `external-systems`, the 22-rule absorption — all withdrawn.
- Generalising project-local facts. They stay in the project, where the plugin defers to them.
- Replacing `superpowers`.

## 3. The filter (why this shrank from 54 to ~5)

The wrong test was *"would this bite a stranger?"* — every true statement about software
passes it. The right test:

> **Is this a *fact the model already has*, or a *choice where you have a side*?**

- **Facts** — constant-time compare, UTC vs calendar semantics, at-least-once dedupe,
  async-after-commit, retry + dead-letter, tenant scoping, mass assignment. A capable model
  **already knows every one.** It doesn't fail to *know* them; it fails to **stop and apply**
  them — which is exactly what the gate already forces. **Marginal. Do not ship.**
- **Preferences** — contested choices where half the industry does the opposite and has
  reasons. **A model cannot infer your side.** **This is the entire value.**
- **Wrong-default** — the model's *unprompted behaviour* is actively incorrect. Narrow, but
  worth stating.

## 4. The distillation (the soul) — corrected

A first draft distilled the Go/JVM opinions as *"explicit over magic — no Spring, no DI
container, no annotations."* **That was wrong, and instructively so:** it mistook the
**nominal** for the **structural** — the precise failure the design rule exists to prevent.

The evidence: the same author is happy in **NestJS**, a decorator-heavy DI container, with
the rule *"all services and controllers wired in one `app.module.ts` — you can see
everything in one place, instead of wiring modules all over the project."* The conviction was
never anti-framework.

> **The composition is readable in one place.** One root module, one configuration class, one
> `main()` — open it and see what the application is made of. **A DI container is fine.
> Wiring you have to grep for is not.**

The enemy is **scattering**, not the framework. Every "no X" was a dialect of that one
sentence:

| Stack | How it says the same thing |
|---|---|
| Go | construct in `main()`; no `init()` magic, no package-level singletons |
| JVM worker | `main()` + constructor wiring — a container buys nothing here |
| NestJS | one `app.module.ts`, not a module tree |
| **Spring** | **explicit `@Configuration` + `@Bean` over `@ComponentScan` discovery** — same conviction, Spring's dialect |

**Therefore: the conviction goes in the language-free core. Only the dialect goes in a
blueprint.** No prohibition on any framework survives.

### 4.1 The conviction underneath the conviction

Read across the whole corpus and "one place" is not a wiring rule — it is the organising
principle:

- *"One place to change when the vendor changes. One place to read to know what we send them."*
- *"Define once in the contracts location"* · *"One writer — funnel through one choke point"*
- *"If duplication is forced, name one copy canonical"* · *"Publish the mapping table"*
- *"There is one `GATE.md`, consumed three ways"* — applied to this plugin itself

**One place to look. One place to change.** Two copies drift; scattered means you cannot see
the whole.

And it closes the loop with the gate's first line — **"No decision is made in isolation."**
That is unanswerable in a codebase whose shape is only discoverable by grep. **Legibility is
not an aesthetic; it is the precondition for the judgment this plugin demands.**

## 5. What ships

### 5.1 `skills/backend-shape/` — NEW · universal · loads automatically
The files/folders/code philosophy. Names no language. Trigger: **designing or bootstrapping
a backend service or component where the shape is your call.**

- **The composition is readable in one place.** Whatever the framework, choose the mode
  where wiring is centralised and legible over the mode where it's scattered by
  auto-discovery. A DI container is fine; wiring you have to grep for is not. *(the soul)*
- **Organise by feature, not by layer.** A feature owns its transport, decisions, and data
  access together. Layer-folders scatter one change across three directories and make a
  feature's blast radius invisible.
- **Each layer does only its job.** Transport parses, validates, delegates — decides
  nothing. Logic decides — knows no transport, writes no queries. Data queries — holds no
  policy.
- **Typed DTOs at every boundary; never the storage model on the wire.** They change for
  different reasons — couple them and a column rename becomes an API break.
- **A framework is a decision to surface, not a default.** Reach for the smallest thing that
  does the job — *and then wire it legibly.*
- **Config is read once, at startup, into a typed value.** Missing required config crashes
  at boot; optional gets an explicit default. Never read the environment from inside a call
  path.
- **One interface per axis of change, not per class.**

**Deference (load-bearing):** in an existing codebase **its shape wins** —
`engineering-standards` §1 outranks this skill. This fires only when the choice is *actually
yours*: greenfield, a new service, or a project with no answer. Stated in the body so it can
never be read as "restructure their repo."

### 5.2 `skills/<language>-backend-blueprint/` — NEW · opinionated · **explicit invocation only**

The author's complete house style for a language. **Deliberately, totally opinionated** —
including library choices, because a library choice *is* a preference, and preferences are
precisely what §3 says to ship.

**Isolation = explicit invocation, and it is stronger than description-gating.** The
`description` must state that the skill loads **only** when the user asks for it **by name**
(e.g. *"use the senior-dephx opinionated Go backend standards"*), and must say plainly: **do
not load for general work in this language** — `backend-shape` covers that. A house style
applied unasked is the "technically correct, wrong context" slop this plugin exists to
prevent.

**Two modes, both explicit:**
1. **Greenfield** — build a new service to this standard.
2. **Full refactor** — bring an existing project *to* this standard.

**Mode 2 deliberately overrides `backend-shape`'s deference and `engineering-standards` §1
("fit the existing structure").** That is not a conflict — it is the authority ladder
working: **human > project > plugin.** *"Fit what's there"* is the correct default precisely
because nobody asked; **invoking this blueprint by name IS the human asking**, and the human
outranks the default. This is the strongest reason the skill must never auto-load: the only
thing permitted to override "fit the existing structure" is an explicit instruction to do so.
The skill body must state this, and must still **surface the scope** before restructuring
(which resources, which layers, in what order) rather than rewriting a repo unprompted.

**Concreteness bar:** the blueprint is used to *build*, not to *cite*. It names and sketches
the canonical helpers, envelopes, and wiring so a **fresh repository can construct them from
this document alone**. The author's helper vocabulary (response helper, safe-query wrapper,
paginated-query executor, etc.) is part of the house style and ships **by name** — that is
opinion, which §3 says is the whole point. What may never appear is a company, product,
repo, host, or a reference to a helper as though it already exists somewhere.

**First: `go-backend-blueprint`.** Scope — the full pattern, buildable from scratch:
- `main` as the composition root: construction order, wiring, graceful start
- **resource cleanup at shutdown** — signal handling, ordered teardown, in-flight drain
- routing + middleware layout
- dependency/config setup
- **the unified background-worker pattern** (and choosing the weakest mechanism that meets
  the reliability bar)
- data-layer interaction patterns, transaction discipline, the panic→domain-error boundary
- **unified response envelope + pagination**
- inter-service wisdom (contracts, clients, tenancy passthrough)

`java-backend-blueprint`, `nestjs-backend-blueprint` follow the same pattern later. **Adding
one = one new directory; zero core changes.**

**Nouns rule for blueprints:** may name **languages and libraries** (that's the job); may
**not** name a company, product, repo, host, or an existing project's helper. The blueprint
must be implementable in a *fresh* project — that's the whole point. Referencing a helper
that exists only in one repo makes it a project skill wearing a language's name.

*(This replaces the thin `go-service-shape`/`java-service-shape` packs from the previous
draft. Their content was always house style, which by this same instinct must not fire
unasked — so it folds in here.)*

### 5.3 The wrong-default rules (~5)

| Rule | Home | Why it ships |
|---|---|---|
| **Replace-vs-merge: determine which before *any* external save/update call.** Assuming merge on a replace endpoint silently deletes everything you didn't send. Read-modify-write — and read first. | `engineering-standards` §3 | Models genuinely assume merge and wipe config |
| **A business "no" is a success.** Success / retryable / poison. "The card was declined" is a *result* — record it and ack. | `engineering-standards` §4 | Models genuinely retry business failures forever |
| **Enumerate what a provider does *not* emit.** Every un-evented mutation needs a poll. Push + reconcile, never push alone. | `engineering-standards` §3 | Models genuinely assume webhook coverage is complete |
| **A control plane's success field means "accepted," not "live."** Verify the artifact's identity, not the status code. | `verify-for-real` | Models genuinely trust `status: done` |
| **A green build with a failed deploy is configuration, not code.** Changing code first destroys the evidence. | `verify-for-real` | Models genuinely edit code first |

### 5.4 `core/GATE.md` — 1 edit
Resolve the **live contradiction**: the gate says *"One consolidated round, not a drip"*;
the source corpus's interviewing skill says *"one question at a time."*

> **Consolidated round for *independent* forks. One at a time only when the answers are
> *dependent*** — when a later question's content changes based on an earlier answer (a
> design tree). Never a drip of independent questions.

No other gate change. It is the only always-on surface and stays brutal.

### 5.5 Verification — `test/smoke.sh` + a nouns check
The plugin preaches *"a build is not a verification"* and cannot verify itself.

1. **Claude** — manifests parse; every `skills/*/SKILL.md` has frontmatter with non-empty
   `name` + `description`; `hooks/hooks.json` parses; the hook is executable and emits the gate.
2. **OpenCode** — the module imports; `config()` appends the skills path; the transform
   injects **exactly once** and is idempotent on re-entry.
3. **Codex** — `install.sh --codex --here` writes the block; **running it twice yields an
   identical file** and preserves surrounding content.
4. **Nouns check** — grep `core/` and every `skills/*/` **except `*-backend-blueprint/`** for
   a denylist of framework/vendor tokens, **word-boundaried** (an un-anchored grep flags
   "plu*gin*" and "en*gin*eering"; a noisy check gets ignored, and an ignored check is worse
   than none). Blueprints are exempt from the *language/library* denylist and **never** from
   the *project*-noun denylist.
5. **Blueprint gating check** — every `*-backend-blueprint/` description must contain the
   explicit-invocation clause. A blueprint that can auto-load is a bug.

### 5.6 README + manifests
- **Blueprints** — what they are, that they load **only on explicit request**, and the
  contract for adding a language: one directory, zero core changes.
- **superpowers** — works alone; sharper together.
- Version → **0.2.0**.

## 6. Layout — flat, not nested

All three consumers discover skills **one level deep** (`install.sh` globs `skills/*/`). A
nested layout would be silently omitted from the Codex block.

**Naming:** `<language>-backend-blueprint`. The nouns check and the gating check both key
off it.

## 7. Interop with `superpowers`

Skills are static markdown and cannot self-disable. The only surface with runtime knowledge
is the **gate injection** — three thin adapters over one `GATE.md`. Each detects superpowers
and, if present, appends one routing line. **Correctness never depends on detection**: the
plugin works standalone; detection only sharpens routing.

## 8. What is explicitly NOT ported

- All project-local facts. *"They are the right kind of local."*
- Every rule in the "facts" class (§3).
- The interviewing skill: ~75% already in the gate; the novel half is `brainstorming`'s job.
- Rules assuming a microservice fleet with a broker (kill-switches across N consumers,
  producer boot-order, never-create-the-stream, shared-DB deploy ordering). **One
  architecture, not portable judgment.**
- **Any prohibition on a framework.** See §4.

## 9. Rollout

1. Gate cadence fix (1 edit).
2. `backend-shape` — the universal centrepiece.
3. `go-backend-blueprint` — the big one; explicit-invocation only.
4. The five wrong-default rules.
5. superpowers detection + static deference notes.
6. `test/smoke.sh` + nouns check + blueprint-gating check.
7. README + version 0.2.0.

## 10. Risks

- **A blueprint auto-loads** and imposes a house style on a stranger's repo. This is the
  worst failure available here. Mitigated by the §5.5 gating check — mechanical, not
  aspirational.
- **`backend-shape` reads as "restructure their repo."** Mitigated by the §5.1 deference
  clause.
- **A blueprint leaks project nouns** and becomes unusable in a fresh project — the exact
  opposite of its purpose. Mitigated by the project-noun denylist applying to blueprints.
- **Wording softens.** Preferences stated softly read as suggestions and change nothing. One
  line, with teeth, or it doesn't ship.
- **Scope creeps back.** §3 is the control: if the model already knows it, it doesn't ship —
  no matter how true it is.
