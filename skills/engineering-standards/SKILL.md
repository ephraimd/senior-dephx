---
name: engineering-standards
description: Use when writing or reviewing any non-trivial code - adding a file, a model, an endpoint, a third-party integration, or a constant. Covers contract programming (no scattered magic values), keeping to the project's existing file/folder structure, isolating external services, layer discipline, error handling, and avoiding AI-looking code. Also use when a change "works" but feels like it was bolted on rather than fitted in.
---

# Engineering Standards

How code should be *shaped* once you have decided what to build. The decision itself is
`software-engineer-intuition`; this is the craft that follows it.

None of this names a language or framework. **Read the project's own rules and mirror its
existing shape first** - these standards tell you what to look for and what to refuse.

## 1. Fit the existing structure

The project already has a pattern. Find it and obey it.

- **Do not invent a parallel structure.** If features live in a certain shape, yours lives
  in that shape too. A new top-level directory is a decision to surface, not to make while
  nobody is looking.
- **Do not create a new file when the logic belongs in an existing one.** "It felt cleaner
  in its own file" is how a codebase acquires six services that should be one.
- **Respect the layer split.** Whatever the project's layers are - transport, business
  logic, data, presentation - keep each doing only its own job. Business decisions do not
  belong in a request handler; HTTP status codes do not belong in a service; queries do not
  belong in a view.
- **Build bulk on top of single.** A batch operation wraps the single-item path. Two
  divergent implementations of the same rule will disagree eventually - usually about
  money.

## 2. Contract programming

**A magic value used in more than one place is a missing contract.**

- Do not scatter literals that encode a cross-cutting rule: statuses, limits, windows,
  fee rates, currencies, keys, type discriminators.
- Define once in the project's contracts location; reuse everywhere. If there isn't one,
  proposing it is a decision to surface.
- **The test:** if changing this number in one place without the other would be a bug, it
  is a contract. Two copies of a rule that must agree will drift - and the drift is
  invisible until it costs something.
- Values that must agree across a boundary the compiler cannot see (backend ↔ frontend,
  service ↔ service) get a comment on each side naming the other. They cannot be checked;
  they can at least be findable.
- Spotting a broken contract while passing through is a reason to fix it.

## 3. Isolate the outside world

Third-party integrations - payments, mail, storage, AI, SMS - live behind the project's
own boundary (a package, a client module), never inlined into business logic.

- One place to change when the vendor changes. One place to read to know what we send them.
- Never let a vendor's shape leak into your domain model.

## 4. Validate at the edge, decide in the middle

- Validate and sanitise untrusted input before it reaches storage, at the layer the project
  designates. Never persist unsanitised user input.
- Wrap errors with context as they travel up. An error that arrives as `EOF` with no story
  costs an hour.
- **Branch on typed errors, never on error text.** Message-matching breaks silently the
  moment someone rewords a string - and nothing tells you.
- Fail loudly at boundaries you cannot recover. A swallowed error that returns an empty
  list is how an entire feature quietly disappears from production.

## 5. Money, state, and anything irreversible

- **Idempotency is not optional.** Anything that moves money or state must be safe to run
  twice: serialize the decision, re-read it inside the transaction, and no-op if it already
  happened. A check outside the transaction is not a guard.
- **Guard with an invariant, not an allow-list.** "Not already settled" survives a new
  state being added; an enumerated list of allowed states silently excludes it.
- **Snapshot the terms.** Anything that governs a transaction - a rate, a window, a policy -
  must be frozen onto the record at the time, not read live afterwards. Otherwise changing
  a setting rewrites history.
- **One writer.** If two paths can change the same balance or status, they will disagree.
  Funnel them through one choke point.

## 6. Don't write AI-looking code

- **No tutorial comments.** Don't narrate what the next line does.
- **Comment the non-obvious *why*,** especially a constraint the code cannot show: why this
  order, why this value, what breaks otherwise. If the reason lives only in your head or in
  a PR thread, it belongs in the code.
- **No comments addressed to the reviewer.** "Fixed the bug where…", "as requested",
  "this is now correct" - noise the moment it merges.
- Match the surrounding code's naming, density, and idiom. Code that reads like a different
  author wrote it is a smell even when it's correct.
- Prefer deleting to adding. The best version of most changes is smaller than the first
  draft.

## Red flags

| You see… | It means |
|---|---|
| The same literal in two files | A missing contract |
| A vendor SDK type in a domain model | The integration boundary leaked |
| `if err != nil { return err }` all the way up with no context | Nobody will be able to debug this |
| `strings.Contains(err.Error(), ...)` or equivalent | Branching on prose; use a typed error |
| A status check outside the transaction that writes | Not a guard - a race |
| A new top-level directory | A structural decision made silently |
| A second implementation of an existing rule | It will drift, and drift costs money |
| A comment explaining what, not why | Delete it |
| A setting read live where it should have been snapshotted | The terms can change after the fact |
