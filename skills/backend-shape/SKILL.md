---
name: backend-shape
description: Use when designing or bootstrapping a backend service, adding a resource or feature to one, deciding where a new piece of code should live, or working in a project whose structure gives no clear answer. Covers the one-place composition rule, dependencies handed in rather than reached for, organising by feature rather than layer, what each layer may and may not do, typed boundaries, framework choice, startup configuration, and interface seams. In an existing codebase that codebase's shape wins - this fires only when the choice is genuinely yours.
---

# Backend Shape

`software-engineer-intuition` decides *what* to build. `engineering-standards` shapes the
code once you know. This is the shape of the thing they both live inside: where code goes,
and what that arrangement is obliged to make visible.

## The rule

**The composition is readable in one place.** One root module, one configuration
entrypoint, one composition function - open it and see what the application is made of:
what it depends on, what it exposes, what it reaches out to. **A dependency-injection
container is fine. Wiring you have to grep for is not.**

This is not an argument against frameworks, containers, decorators, generated code, or any
other machinery. Declare your dependencies however the project's tooling wants them
declared. The rule is about *where* the declaration lives: assembled at one root, not
sprinkled across the tree so that the only way to answer "what is this application made
of" is to search for the pieces and hope you found them all.

The gate opens by stating that **"No decision is made in isolation."** That sentence is
unanswerable in a codebase whose shape is only discoverable by search. You cannot weigh a
change against a system you would need an afternoon to read. **Legibility is not an
aesthetic; it is the precondition for the judgment this plugin demands.** Every rule below
is that one rule applied to a different part of the tree.

## 1. The existing shape wins

**In an existing codebase, its shape outranks everything below.** `engineering-standards`
§1 "Fit the existing structure" is the higher authority and it does not yield to this
skill. A project that organises by layer, wires in three places, and hands its storage
types straight to the transport is a project you extend *in that shape*, today, without
comment in the diff.

- **Never restructure a codebase because of this skill.** Nothing here is a licence to move
  a file. Arriving in someone's repository and reshaping it toward a doctrine they did not
  ask for is exactly the failure this plugin exists to prevent - it just arrives wearing
  better clothes.
- **A migration is a decision to surface, never one to make while you are in there.** If
  the existing shape is genuinely costing them, say so once, name the cost in their terms,
  and let the human decide. Until they decide, you keep writing their shape.
- **This fires only when the choice is actually yours**: a greenfield service, a new
  service in an existing fleet, or a spot where the project genuinely has no answer for
  where your change goes. That last case is narrow and it is the one you will over-claim.
  Look harder for the existing answer before concluding there isn't one - two similar
  features and a shared folder *are* an answer.

## 2. Organise by feature, not by layer

**A feature owns its transport, its decisions, and its data access together.** One folder
per feature; everything that changes when the feature changes lives inside it.

- Folders named for technical layers scatter a single change across three directories.
  The reviewer then sees three diffs and no feature.
- **A feature's blast radius should be a folder.** When the layout is technical, nothing
  tells you what a change can reach. You find out in production, from someone else.
- **A feature reaches another feature through its exposed surface, never into its
  internals.** An internal that two features both need is a shared thing that has not been
  named yet: find it, name it, move it to the shared place.
- Shared building blocks live in one shared location. `engineering-standards` §1 owns *when*
  something has become shared; this owns *where it goes*. A block left sitting inside the
  feature that happened to need it first is a line every later feature has to reach across,
  into internals the rule above just told them not to touch.

## 3. Each layer does only its job

Inside the feature the split still holds. `engineering-standards` §1 states the principle;
this is the shape it takes when the folder is yours to lay out.

- **Transport parses, validates, delegates, and decides nothing.** A branch in a handler
  that changes the outcome is a business rule that now exists in exactly one entry point -
  and the scheduled job that needed it will never find it.
- **The decision layer decides, knows no transport, and writes no queries.** It must be
  callable from a background worker or a message consumer without editing a line. If it
  cannot be, transport has leaked in and the second caller will fork the rule rather than
  reuse it.
- **The data layer queries and holds no policy.** Whether this caller is *allowed* to see
  the row is a decision made above; the query only fetches. Policy hidden in a query is a
  rule nobody reviewing the feature will ever read.
- **Each layer talks only to the one below it.** Transport reaching past the decision layer
  into storage is the shortcut that makes every rule above it optional.

## 4. Typed data-transfer types at every boundary

**Never put the storage model on the wire.** A type that crosses a boundary is declared for
that boundary and for nothing else.

- They change for different reasons. Storage changes when you index, denormalise, or split
  a table; the wire changes when a consumer needs something different. Couple them and a
  column rename becomes an API break, shipped by someone who believed they were renaming a
  column.
- The reverse leak is quieter and worse: a storage type on the wire publishes every field
  anyone adds to it later, automatically, forever. The next migration is an unplanned
  disclosure.
- **This applies to internal boundaries too** - service to service, feature to feature. A
  boundary you own is still a boundary, and the compiler will not warn you when the other
  side changes.
- Mapping between the two is boring code you write by hand. Boring is the point: the
  mapping is where a boundary change becomes a build failure instead of an incident.

## 5. A framework is a decision to surface, not a default

- **Reach for the smallest thing that does the job, then wire it legibly.** The question is
  never what everyone uses; it is what this costs to keep, to upgrade, and to leave.
- **Adopting one is a decision to surface**, not a default you arrive with. It lands in the
  composition root, in the build, in the deploy, and in the head of every person who ever
  reads this service.
- **Never adopt one for a fraction of it.** `engineering-standards` §1 states that cost in
  general; a framework is where it compounds, because leaving one later means rewriting the
  wiring of everything that grew inside it.
- The wiring rule does not bend for the tool. If its default is to discover its own wiring
  by scanning the tree, configure it to be declared at the root instead. A tool's
  convenience never outranks the codebase's legibility.

## 6. Config is read once, at startup, into a typed value

- **Required and missing crashes at boot**, loudly, naming the key. A service that starts
  clean and fails on the first request that happens to need the key has converted a boot
  error into somebody's afternoon.
- **Optional gets an explicit default**, written once where the value is read. Scattered
  fallbacks for the same key are two rules that must agree, which is a contract -
  `engineering-standards` §2 has the rest.
- **Never read the environment from inside a call path.** It is a hidden global read: no
  test can see it, no reader can find it, and the service's real inputs stop being
  discoverable. The typed value *is* the list of what this service needs to run.
- Pass it down from the composition root. A layer that fetches its own config has a
  dependency that does not appear in its constructor, which means it does not appear at all.

## 7. One interface per axis of change, not per class

- An interface exists to absorb a variation you can name: another vendor, another storage
  engine, a fake that lets a test run without the network. That nameable variation is the
  axis.
- **The test: name the second implementation.** If you cannot name a real one, there is no
  axis, and what you have written is a second file that must be edited every time the first
  one changes.
- **A mirror interface for every concrete type is not abstraction, it is paperwork.** It
  doubles the surface, hides the real seams among the fake ones, and buys nothing.
- One seam per feature is usually right, and it usually sits where the feature meets
  something it does not own. `engineering-standards` §3 governs what happens on the far
  side of it.

**Dependencies are handed in, never reached for.** Whatever a unit needs - a clock, a
store, a client, a queue - arrives through its constructor or its arguments. A unit that
reaches out to a global, a singleton, or a service locator has a dependency the caller
cannot see, cannot substitute, and cannot test around. That is the same rule as the
composition one: if it was not passed at the root, the root no longer describes the
application.

**Depend on the abstraction you own, not the one a vendor gave you.** The seam takes your
type; the adapter behind it speaks the vendor's. Otherwise the vendor's shape spreads
through the callers and the seam stops being a seam.

## Red flags

| You catch yourself… | It means |
|---|---|
| Unable to say where the application is wired together | The composition is readable nowhere |
| Adding a top-level folder named for a technical layer | Future changes land in three places |
| Putting a storage type in a response | The next migration is an API break |
| Reading the environment inside a handler | A hidden input, invisible from the root |
| Restructuring someone's repository to match this skill | Their shape wins and you were not asked |
| Reaching into another feature's internals | A shared thing nobody has named yet |
| A handler branching on a business rule | The decision leaked into transport |
| A decision that cannot run without a request | Transport leaked into the decision layer |
| A permission check written into a query | Policy hiding where nobody reviews it |
| Config read lazily on first use | A boot error deferred until a user finds it |
| A unit fetching a global or singleton it was not handed | A hidden dependency nobody can substitute |
| An interface whose second implementation you cannot name | Paperwork, not a seam |
| A large dependency taken on for one function | A permanent cost for a temporary saving |
| "I'll extract it when a third caller shows up" | `engineering-standards` §1 - twice is the trigger |
