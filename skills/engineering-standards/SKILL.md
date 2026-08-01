---
name: engineering-standards
description: Use when writing or reviewing any non-trivial code - adding a file, a model, an endpoint, a third-party integration, or a constant. Covers contract programming (no scattered magic values), keeping to the project's existing file/folder structure, building the simplest thing that works, knowing what the code costs to run (no I/O in a loop, bounded inputs), isolating external services, layer discipline, error handling, and avoiding AI-looking code. Also use when a change "works" but feels like it was bolted on rather than fitted in.
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
- **Determine replace-vs-merge before any external save.** An "update" endpoint that
  *replaces* silently deletes everything you did not send. Read the current state, modify
  it, write it back whole - and read first. Assuming merge is the default failure here.
- **Enumerate what a provider does not emit.** Event coverage is never complete. Every
  mutation the provider does not tell you about needs a poll to find it. Push plus
  reconcile; push alone loses data quietly.

## 4. Validate at the edge, decide in the middle

- Validate and sanitise untrusted input before it reaches storage, at the layer the project
  designates. Never persist unsanitised user input.
- Wrap errors with context as they travel up. An error that arrives as `EOF` with no story
  costs an hour.
- **Branch on typed errors, never on error text.** Message-matching breaks silently the
  moment someone rewords a string - and nothing tells you.
- Fail loudly at boundaries you cannot recover. A swallowed error that returns an empty
  list is how an entire feature quietly disappears from production.
- **A business "no" is a success.** Three outcomes exist: success, retryable failure, and
  poison. "The card was declined" is a *result* - record it and acknowledge the message.
  Retrying a business failure until it succeeds is a loop that never ends.

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

## 6. The simplest thing that works

Generality you were not asked for is a cost you pay forever and a bet you usually lose.

- **Build for the requirement that exists.** Not the one you imagine arriving. The test:
  **name who asked for it.** If the answer is "it might be useful later", it is not a
  requirement, it is a guess with maintenance attached.
- **One implementer is not an abstraction.** A wrapper, options bag, strategy, or config
  flag with exactly one real case is indirection charging rent. Inline it until a second
  case appears and shows you where the seam actually is.
- **A flag that no caller sets, or that only ever takes one value, is dead.** Delete it
  rather than carrying it.
- **Solve it where it happens.** Reaching for a framework, a queue, or a cache before you
  have the problem they solve buys operational surface, not capability.
- **Delete, do not comment out.** History remembers. Commented-out code is a question every
  future reader has to answer.

Simple is not the same as short. A dense one-liner nobody can read is not simpler than four
obvious lines - it has just moved the cost onto the next person.

## 7. Know what it costs

Correct and unusably slow is a bug report. Know the shape of the work before shipping it.

- **Say what runs per item and what runs per request.** If you cannot, you do not yet know
  what you wrote.
- **No I/O inside a loop.** A query, HTTP call, or file read per element is the single most
  common way a feature that worked on ten rows dies on ten thousand. Fetch the set in one
  call, then map over it in memory.
- **Filter and aggregate where the data lives.** Pulling a table across the wire to count,
  sum, or filter it in application code moves the cost from an engine built for it to one
  that is not - and to memory that has a limit.
- **Ask what makes this slow, and whether a user can supply it.** Input a caller controls -
  a page size, a date range, a list of ids, an upload - is an input that will eventually be
  large, whether by accident or on purpose. Bound it.
- **Name the growth when it is not flat.** Linear is usually fine. A nested loop over two
  collections that both grow, a query inside a loop, or a repeated scan is where it stops
  being fine, and it is worth one sentence in the PR.
- **Whatever you filter or join by wants an index** - and adding one on a large live table
  is itself a migration with a cost. Say so rather than discovering it in production.

- **A write costs more than its own table.** Every index on it is rewritten, every foreign
  key is checked, every trigger fires, and every cascade reaches a table you did not name. An
  insert into a heavily-indexed table is not the cheap operation it reads as, and a cascade
  nobody traced is a write nobody reviewed.
- **Say what the statement locks, and who waits behind it.** A long transaction, a bulk
  update, or an index build on a live table blocks somebody - readers, writers, or the next
  migration. If you cannot name who waits, you do not yet know what you wrote.
- **Ask what else reads this table while you write to it.** A table is rarely used by one
  path. Your query shares its locks and its cache with every other query on it, and the one
  that degrades will not be yours.

Measure before optimising anything subtle. But the items above are not subtle; they are
shape, and shape is visible while writing.

**None of this licenses building for scale you do not have.** §6 still governs: the simplest
thing that works. Each check above costs a sentence of thought and is answerable while
writing - that is what makes it shape rather than optimisation. Sharding, caching layers,
read replicas and denormalised copies are the opposite: they answer a problem you must
already have, and reaching for one early buys operational surface and a second copy of a
rule that will drift.

## 8. Don't write AI-looking code

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

## If someone names a principle

These rules are the usual principles, written as things you can check. When a human asks
whether something is SOLID, DRY, or KISS, map the word to the rule and answer with the
rule - not with the definition.

| They say | The rule that already covers it |
|---|---|
| Single responsibility | §1 one file, one job · `backend-shape` §3 each layer does only its job |
| Open/closed, Liskov, interface segregation | `backend-shape` §7 one interface per axis of change - name the second implementation |
| Dependency inversion / "use DI" | `backend-shape` §7 dependencies handed in, never reached for; depend on the abstraction you own |
| DRY | §2 a value repeated is a missing contract · §1 build bulk on top of single |
| KISS / YAGNI | §6 the simplest thing that works - name who asked for it |
| Big-O, "is this efficient?" | §7 know what it costs - what runs per item, and what a caller can make large |

Naming the principle is not the work. **Two copies of a rule that must agree will drift,
and the drift is invisible until it costs something** is the work.

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
| An update that sends only the fields you changed | A replace endpoint deletes the rest |
| A query, request, or file read inside a loop | It works on ten rows and dies on ten thousand |
| Fetching a collection to count or filter it in memory | The engine could have answered that |
| An unbounded limit on anything a caller controls | Someone will eventually send all of it |
| An interface, wrapper, or flag with one real case | Indirection charging rent - inline it |
| Building for a requirement nobody stated | Name who asked, or do not build it |
| Code commented out "for later" | History remembers. Delete it |
| A provider's events trusted to cover every change | The gaps surface only as missing data |
| A business rejection queued for retry | A result retried as though it were a fault |
