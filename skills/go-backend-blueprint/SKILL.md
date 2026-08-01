---
name: go-backend-blueprint
description: Use ONLY when a human explicitly asks for this blueprint by name - one person's opinionated house style for a Go backend service, in either greenfield mode (build a new service to this standard) or full-refactor mode (bring an existing one to it). Covers composition and lifecycle, background workers, the HTTP layer and its single response envelope, the data layer, and inter-service contracts. Never load, apply, or use it for general Go work, for any other language, or on its own initiative - unrequested, it imposes one person's taste on a repo whose own shape wins.
---

# Go Backend Blueprint

`backend-shape` is the universal philosophy: where code goes, and what that arrangement is
obliged to make visible. **This is one dialect of it** - a single person's house style for
a Go backend, down to the library choices. Read `backend-shape` for the why. This file does
not restate it.

**It is not universal. It is not the only good answer. It is not to be applied unasked.**
Another Go shop could reject every line below and still be building the right thing. What
this blueprint offers is not correctness, it is coherence: one set of answers that fit each
other, already paid for in production.

## Two modes

- **Greenfield.** A new service built to this standard from the first commit. Follow the
  spine; read each reference as you reach its layer.
- **Full refactor.** An existing project brought to this standard. Same spine, but the
  scope is agreed before anything moves. See **Refactor discipline**.

There is no third mode. "Apply a bit of this while I am in here" leaves a service wearing
two shapes, which is worse than either shape alone - now every reader must first work out
which half they are standing in.

## Authority

**This skill overrides `backend-shape`'s deference to the existing shape, and it overrides
`engineering-standards` §1 "fit the existing structure."**

That is not a conflict. It is the plugin's authority ladder working as designed:
**human > project > plugin.**

"Fit what's there" is the correct default *precisely because nobody asked*. It exists to
stop an agent imposing a doctrine on a stranger's repository. **Invoking this blueprint by
name IS the human asking** - and the human outranks the project, which outranks every
default this plugin ships. Once named, deference stops being humility and becomes a refusal
to do the job you were handed.

**This is the entire reason it must never auto-load.** A blueprint that fires on its own
has no human anywhere in that ladder - only a plugin rewriting someone's service to one
stranger's taste. That is the worst failure available in this project, worse than any bug
this standard prevents, because it destroys the trust that lets any of these skills run at
all. Loaded when named. Never otherwise.

## Refactor discipline

Being invoked authorises the standard. It does not authorise a rampage.

- **Surface the scope before you restructure.** Name the resources, the layers, the order
  of work, and explicitly what stays untouched. Get agreement first. A refactor whose
  extent the human discovers from the diff is a refactor they cannot review, and an
  unreviewable diff gets rubber-stamped or abandoned - never read.
- **Never rewrite a repo in one pass.** One resource at a time, each landing green,
  shippable, and revertible on its own. A branch that moves everything at once cannot be
  bisected when it breaks, so its blast radius is the whole service forever.
- **Behaviour is frozen while shape moves.** No bug fixes, no output changes, no "while I
  was in there" improvements inside a restructuring commit. Mixed commits make both halves
  unreviewable and hide the regression in the noise.
- **Say what you are not doing.** The parts left in the old shape are a deliberate boundary.
  Unstated, they read as an abandoned job, and the next person re-litigates a decision you
  already made.
- **The existing shape still gets a hearing.** Where the project already solves something
  better than this blueprint does, say so and keep theirs. Being asked for a standard is not
  being asked to stop thinking.

## The spine

The non-negotiables, on one screen. The references explain how; this is the checklist.

- **`main` is the composition root.** Every dependency constructed there, explicitly, and
  passed in. Wiring you have to grep for is an application nobody can hold in their head.
- **No container. No `init()`. No package-level singletons. No global `db` handle.** State a
  constructor does not name is state a test cannot replace and a reader cannot find.
- **Feature folders.** One folder per resource; everything that changes when the feature
  changes lives in it. Top-level folders named for layers scatter one change across three
  directories and show the reviewer three diffs and no feature.
- **Layers do only their job.** Handler parses, validates, delegates. Service decides.
  Store queries. A branch in a handler is a business rule that exists in exactly one entry
  point, and the worker that needs it will fork it instead.
- **Typed DTOs at every boundary**, including internal ones. The storage struct never
  reaches the wire: it publishes every field anyone adds to it later, automatically,
  forever. `map[string]any` crossing a boundary is a contract no reviewer can read and no
  compiler can check.
- **One response envelope.** Every endpoint, success and failure, same shape. Two envelopes
  means every client writes two parsers and gets one of them wrong in the path you never
  test.
- **Every list endpoint paginates through one executor.** No exceptions and no "this table
  is small" - the unbounded query is a full scan waiting for the tenant who makes it fatal,
  and it will not be your tenant.
- **Config is read once at boot into a typed struct.** Required-and-missing panics at
  startup, naming the key. `os.Getenv` inside a call path is a hidden input: invisible from
  the root, unreachable from a test, and it turns a boot error into somebody's afternoon.
- **Graceful shutdown, ordered teardown.** Stop accepting, drain in flight, close resources
  in reverse construction order. An unordered exit truncates work that was mid-write and
  leaves the damage for someone else to find.
- **Background work uses the unified worker pattern.** One shape for every job. Bare
  goroutines have no lifecycle, no retry, no dedupe, no observability, and no way to be
  stopped - so the first thing shutdown does is abandon them.
- **gin is the HTTP framework, and it supplies routing and middleware - not the guarantees
  above.** The envelope, the middleware order, the pagination executor and the typed context
  accessor are still written once, by hand, and are the only permitted implementations. gin's
  context is `map[string]any`: reading a request value by raw string key scatters a magic
  literal through every handler, which is a missing contract wearing the clothes of a
  convenience.
- **GORM is the data layer, and it never owns the schema.** Migrations are versioned SQL.
  `AutoMigrate` cannot express a policy, a grant, a check constraint or a partial index, so a
  schema it manages is one whose real guarantees are invisible to it - and invisible
  guarantees are the ones that get dropped. Models are storage types and never cross a
  boundary; returning one is a single line, which is exactly why it is a review red flag.
  `Preload` is deliberate, because association loading inside a loop is the N+1 that worked
  on ten rows. Raw SQL where the query shape genuinely demands it, inside the store, never as
  an escape from the layer.

## References

The concrete patterns live in these files. Read one when you reach its layer; do not read
all five up front.

| File | Read it when |
|---|---|
| `references/composition-and-lifecycle.md` | Writing `main`: wiring order, graceful shutdown, which resource owns and closes what |
| `references/background-work.md` | Any work that is not a request: the unified worker pattern, retries, dedupe, scheduling |
| `references/http-layer.md` | Routing, middleware, the response envelope, pagination, identity at the edge |
| `references/data-layer.md` | Queries, transactions, the panic boundary, migrations, connection pooling |
| `references/inter-service.md` | Calling another service or a vendor: contracts, typed clients, tenancy passthrough, vendor boundaries |

The table is the contract those files satisfy: those paths, those subjects, nothing
quietly relocated or merged. An index that drifts from its references is a lie told to
whoever trusted it, and one wrong entry retires the whole table. If you move a file or
fold one subject into another, this table changes in the same commit or it is already
wrong.

**Status: the reference code has not yet been converted.** The five files still show
`net/http` and `database/sql`. The spine above is the current standard; where a reference
contradicts it, the spine wins and the file is pending. This note exists because an index
that quietly disagrees with its references is the lie this table is meant to prevent, and
a half-converted standard that does not say so is worse than either shape alone.

They are written to be built from, not cited. Every helper the standard names is defined
in one of them, so a fresh repository can be constructed from these five and nothing else.
Where one references another's work - the response envelope, the transaction helper, the
queue - it names the file that owns it rather than restating it, because the restatement
is the copy that drifts.
