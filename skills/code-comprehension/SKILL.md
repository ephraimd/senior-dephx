---
name: code-comprehension
description: Use before editing, refactoring, extending, or debugging code that already exists - and before writing a spec or plan against it. Forces you to read the real code rather than recall it - trace the path end to end, check a function is even reachable before touching it, learn why each part is there, and verify every fact the change rests on by reading the source. Also use the moment you notice you are describing behaviour you have not actually opened, or a fix passes its tests but you cannot say why it is correct.
---

# Code Comprehension

**Your memory of this code is not evidence. The source is.**

`software-engineer-intuition` decides *what to build and what it affects*. This one
establishes *what the code you are touching actually is* - before you change it.

They fail independently. You can produce a flawless Change Brief - right blast radius,
right prior art, right pattern - resting entirely on a field name you misremembered. The
brief was never wrong about the world; it was wrong about the code.

**When this does not apply:** genuinely new code with no surrounding context to honour.
There is nothing to comprehend in an empty directory. Match the effort to what exists.

## The gate

Do not write a spec, a plan, or an edit against existing code until you have read the code
it touches. Not skimmed the filenames. Read it.

Ceremony scales with what the change rests on. A one-line copy fix needs none. A change to
a money path, an auth check, a shared contract, or anything whose behaviour you are
*asserting* rather than *reading* needs all of it.

## 1. Place it

Before the detail: what job does this code do, who calls it, and who would notice if its
behaviour changed? If you cannot say that in one sentence, you are not ready to change it.

## 2. Trace the real path, with line references

Follow the actual execution, opening each hop:

- **Entry to exit.** Request or event in → whatever the framework runs before your handler
  (middleware, guards, filters, interceptors, decorators) → the handler → what it calls →
  external calls → back out. For data: producer → store → consumer.
- **Order matters.** Know what runs before what, and what "already handled" means in this
  framework. Two layers that both look like they authorise a request may not agree, and the
  second one may not have been written with the first one's exceptions in mind.
- **Follow the error path, not just the happy one.** Where is a failure caught, transformed,
  swallowed, or re-thrown? What status and shape actually reach the caller? An error that is
  logged and swallowed is a silent failure with a paper trail nobody reads.
- **Follow money, credentials and personal data with extra care.** These are the paths where
  being approximately right is indistinguishable from being wrong, until it costs something.

Note `file:line` as you go. If you cannot point at the line, you did not read it.

## 3. Check it is reachable before you touch it

**Every time, before refactoring, fixing, optimising, or even tidying a function: find its
callers.**

- **Nothing calls it?** It is dead. Delete it. Do not improve it. Polishing dead code is
  effort spent making the codebase harder to read, and it hides the fact that it should be
  gone.
- **Something calls it?** Enumerate what, and how. A change to its signature, return shape,
  or error behaviour reaches every one of them - and across a repository boundary, one
  side's type-check proves nothing about the other's runtime.
- **Two functions that look like a pair are often not interchangeable.** Confirm which is
  live before assuming either.

## 4. Learn why it is the way it is

For each part you will touch or depend on, answer *why is this here?*

- What breaks if it is removed or simplified? What invariant does it hold - an idempotency
  claim, a security boundary, a backwards-compatibility promise, a guard against one
  specific input that once caused an incident?
- Read the signals the author left: comments that explain intent rather than mechanics,
  the commit that introduced the line, the test that pins it.
- **Terse or ugly code is usually load-bearing.** Assume intent before assuming mistake. The
  weird branch is where the bug report went.
- Separate **essential** (encodes a real requirement) from **incidental** (just how it was
  written). Match the essential. You have latitude on the incidental.

## 5. Verify every load-bearing fact against the source

List what the change rests on. Confirm each by reading, not remembering.

- **Names and shapes.** Read the type *and* the code that populates it. A type can be `any`
  at the boundary, or accurate about a field the producer never sets.
- **"X is registered / applied / global."** Confirm the wiring. Defined is not wired.
- **"This status propagates."** Trace it through every transform between throw and caller.
- **Serialized shape ≠ returned shape.** A wrapper, envelope, or interceptor between the
  function and its consumer changes what arrives. Unit tests assert the return value and
  never see it.
- **Config is a fact too.** A correct implementation reading a variable that points at the
  wrong thing is indistinguishable from a broken implementation - and it fails silently,
  because nothing is throwing.

If a fact is not something you just read, it is not verified. Where reading cannot settle
it, run the smallest possible probe - one real call, one query, one log line - rather than
shipping the guess.

**Passing tests are not evidence here.** Tests are written from the same understanding as
the code. When that understanding is wrong, they agree with it and go green. A test can
only tell you the code does what you *believed*; it cannot tell you the belief was right.
That is what reading the source, or calling the real thing once, is for.

## 6. Flow with the grain

Default: match what is there. If your change feels like it is fighting the code, you have
probably missed the pattern rather than found a flaw.

Redesign is a different mode, and only when it was asked for. Even then, understand the
current design and its reasons first, so the change is a deliberate improvement with the
trade-off named - not an accidental break dressed as a cleanup. Say what you are departing
from and why.

`engineering-standards` owns how the resulting code should be shaped. This skill only gets
you to the point of knowing what you are shaping it around.

## Output: the understanding brief

Before planning or editing, a few lines - it front-loads the work rather than adding to it:

> **What it does:** the path's job in one sentence, and the invariant it protects
> **How it really works:** the traced flow with `file:line` for what you will touch, and the error path
> **Reachable:** who calls what you are about to change
> **Verified:** each load-bearing fact, and how you confirmed it
> **Mode:** flowing with the pattern, or a deliberate departure - and why

No brief, not ready to plan.

## Red flags - you are recalling, not reading

| You catch yourself… | Reality |
|---|---|
| "I remember this carries `X`" | Read the type *and* what populates it |
| "I'll just clean up this function" | Find its callers first. None → delete it |
| "These two do the same thing" | Confirm which is live before touching either |
| "That guard/middleware handles it" | Confirm it is wired, not just defined |
| "The error obviously propagates" | Trace every catch between throw and caller |
| "This code is over-complicated" | It may hold an edge case. Find the why first |
| "I'll match the pattern from memory" | Open two real siblings and read them |
| "Tests pass, so the shape is right" | They may encode your own wrong assumption |
| "The types check, so the data is right" | Types stop at the boundary; payloads do not |
| "It's a small change, I can skip the trace" | Small edits in the wrong place is how silent breaks ship |
| Describing behaviour you have not opened | Open it |
