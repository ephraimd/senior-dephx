---
name: software-engineer-intuition
description: Use BEFORE implementing, changing, or adding anything non-trivial - a new page, feature, endpoint, model, worker, or any change touching money, auth, migrations, or shared contracts. Forces a big-picture pass (blast radius, prior art to reuse, side effects, product value, engineering pattern) and a short Change Brief before code. Also use mid-flight when a change "works" but you cannot say what else it touches, or when you catch yourself writing a parallel variant of something that already exists.
---

# Software Engineer Intuition

The anti-slop gate.

**Slop = code that is technically correct but breaks existing rules, does not fit the big
picture, violates system boundaries, or cannot be maintained.** Correctness is the floor,
not the goal.

**This skill is the source of truth for how to think, decide, and scope a change.** Where
generic tooling guidance overlaps or conflicts with it, this wins. Project files remain
the source of truth for *what* the technical rules are - the stack, the layout, the
contracts. This one governs *how you decide*.

Where a project's own rules conflict with this skill, **the project wins on facts** (its
architecture, its conventions) and this skill wins on *procedure*. Where the human's
explicit instruction conflicts with either, **the human wins** - and you say so out loud
rather than silently applying your default.

No decision is made in isolation.

## When to Use

Before any non-trivial change. Also mid-flight, the moment you notice:
- you are about to create a second way to do something that already exists,
- a change works but you cannot name what else it touches,
- you are writing code to make a compiler or test pass rather than to a pattern.

## Step 1 - Calibrate (never over-process)

Match the ceremony to the blast radius. Process-slop is still slop: a typo fix gets
nothing.

| Tier | Looks like | Required |
|---|---|---|
| **Trivial** | typo, copy tweak, padding, comment | Nothing. Just do it. |
| **Local** | one component or function, no shared contract, no schema change | Two lines: prior art + what breaks |
| **Structural** | new page/endpoint/model/worker/hook, shared contract, new dependency | Full Change Brief + ask (Step 4) |
| **Systemic** | money, auth, settlement, migrations, cross-resource, deploys, anything a user cannot undo | Full Brief + ask + explicit side-effect trace + a test |

When torn between two tiers, take the higher one.

## Step 2 - Answer the five questions (research, do not guess)

Questions 1-3 are answered by **reading the codebase**, never by asking the human.

Where the change touches code that already exists, the facts behind them must be *read,
not recalled* - a field name, a wiring, an execution order, a status you believe
propagates. `code-comprehension` owns that: trace the path, check the function is even
reachable, verify each fact against the source. A brief can be right about blast radius,
prior art and pattern, and still rest entirely on a misremembered shape.

1. **What wheel am I reinventing?** Search before writing, and search for the *behaviour*,
   not for the name you would have given it - prior art almost never carries your word for
   it. Three passes, each finding what the others miss: **this repo** (the shared
   directories, the nearest sibling feature, the call sites of anything shaped like this),
   **what is already installed** (a package the project depends on for one thing usually
   does four), and **the language's own library**. If I am about to write the same shape a
   second time, **extract it into a reusable primitive** (a shared component dir, a package,
   a helper, a hook, a choke point) instead of copying it. Reuse beats invention; extraction
   beats duplication. `engineering-standards` §1 owns what the answer obliges - including
   the inverse, where the wheel being reinvented is a dependency added for something the
   project already does.
2. **What breaks?** Who else reads or writes this table, contract, component, or route?
   Which existing rule or invariant could this violate? Trace at least one concrete
   failure scenario end to end.
3. **What boundary does this cross?** Layer boundaries, contract files, the shared client,
   worker vs request path. A new magic string means a missing contract.
4. **How does this serve the user and the business?** What does the user actually get, and
   does it earn appeal or revenue? If you cannot answer, you may be building the wrong
   thing - say so instead of building it well.
5. **What standard pattern applies?** Name it before writing bespoke code: idempotency key,
   advisory lock, state machine, single choke point, upsert, derived read-model, single
   source of truth, snapshot-at-write, fail-safe default. Conform to the pattern; do not
   hand-roll correctness.

## Step 3 - Post the Change Brief (before code)

Structural and Systemic only. Short, in chat, **before touching code**, so it is cheap to
redirect.

> **Blast radius:** local | structural | systemic
> **Prior art:** what exists, what I am reusing, what I will extract
> **Side effects:** who else touches this; the failure scenario I traced
> **Boundaries:** the contract / layer this crosses
> **Product value:** what the user gets and why it is worth building
> **Pattern:** the standard I am conforming to
> **Open forks:** what I need the human to decide

If the brief is boring, the change is safe. If writing it surfaces a fork, stop and ask.

## Step 4 - Ask (the default, not the exception)

**Surface options and check in before building.** Do not silently assume on:
- any **new user-facing surface** (page, flow, email, major component) - present the intent
  plus 2-3 real options first,
- product, UX, or visual judgment calls,
- anything with a genuine trade-off (fairness, money, data retention, irreversibility),
- any rule you would have to bend.

Ask with **informed options**: researched, each with a consequence, and a recommendation.
Never a blank "what do you want?", and never ask what a grep can answer. One consolidated
round for **independent** forks; one at a time only when answers are **dependent** (a
design tree). Never a drip of independent questions.

## Step 5 - Route, do not duplicate

Load the specialist skill for the domain. This skill never restates their content.

**Discover what is available before routing.** List the skills this project and toolchain
actually expose, and prefer a project's own skill over a generic one - it knows the local
facts. This plugin ships the domain-agnostic set:

| Domain | Skill |
|---|---|
| Understanding existing code before changing it | `code-comprehension` |
| Reuse, structure, contracts, naming, integrations | `engineering-standards` |
| Visual quality, density, mobile, de-slop | `ui-craft` |
| Reviewing whether a change survives the data it will have | `reviewing-for-scale` |
| Reviewing a user-facing surface as the newest user | `reviewing-for-ux` |
| Proving a change actually works | `verify-for-real` |
| Branching, commits, attribution | `git-discipline` |

A project's own skills (its stack, its deploy flow, its copy voice) take precedence for
their domain. If no skill covers the domain, read the project's rules files first.

Where `brainstorming` (before a plan) and `systematic-debugging` (on a bug) are loadable,
they own the procedure: route to them rather than hand-rolling a worse version, and keep
Steps 1-4 as yours - they are the judgment no procedure supplies. Where they are not, this
skill is complete without them.

## Red flags - stop and re-brief

| You catch yourself... | It means |
|---|---|
| Adding `FooNew` / `FooV2` beside `Foo` | Extend the original, or extract a shared primitive |
| Pasting a literal that exists elsewhere | A missing contract value |
| "I will just add a flag for this case" | The model or the pattern is wrong |
| Building a page that mostly duplicates an existing page | Compose from the existing one |
| Unable to name who else touches this | Step 2 was skipped |
| Unable to say what the user gains | You are building the wrong thing |
| Writing code so a test or compiler passes | Coding to correctness, not to a pattern |
| Reaching for a new library for something the repo already does | Reinventing and bloating |
| The fix works but you cannot explain why it is safe | You found a symptom, not the root cause |
| Describing existing behaviour you have not opened | You are recalling, not reading - `code-comprehension` |
| Applying your default over the human's stated rule | Their instruction outranks your default |

## Close the loop

After building: verify it actually runs (`verify-for-real`), re-read your own brief, and
state plainly what you did **not** do and what is still unproven. An unverified claim is
slop.
