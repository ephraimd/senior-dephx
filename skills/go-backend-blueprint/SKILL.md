---
name: go-backend-blueprint
description: Use ONLY when a human explicitly asks for this blueprint by name - one person's opinionated house style for a Go backend service, in either greenfield mode (build a new service to this standard) or full-refactor mode (bring an existing one to it). Covers the Gin and GORM service layout and naming, composition and graceful shutdown, background workers, the HTTP layer with its single response envelope and error contract, the data layer and its migrations, and inter-service clients. Never load, apply, or use it for general Go work, for any other language, or on its own initiative - unrequested, it imposes one person's taste on a repo whose own shape wins.
---

# Go Backend Blueprint

`backend-shape` is the universal philosophy: where code goes, and what that arrangement is
obliged to make visible. **This is one dialect of it** - a single person's house style for
a Go backend, down to the library choices and the file names. It is the shape of a fleet
of services that already run in production, written down so the next one is built the
same way. Read `backend-shape` for the why. This file does not restate it.

**It is not universal. It is not the only good answer. It is not to be applied unasked.**
Another Go shop could reject every line below and still be building the right thing. What
this blueprint offers is not correctness, it is coherence: one set of answers that fit each
other, already paid for in production.

## Two modes

- **Greenfield.** A new service built to this standard from the first commit. Follow the
  spine; read each reference as you reach its layer, starting with
  `references/layout-and-naming.md`.
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

### Where this dialect departs from `backend-shape`, on purpose

A dialect that hides its departures from the philosophy it claims is just a contradiction
nobody wrote down. These are deliberate, and each is paid for in the reference that owns it:

- **Three package-level handles: `database.Db`, `config.GlobalConfig`, `logger.Logger`.**
  `backend-shape` says dependencies are handed in, never reached for. Here those three are
  reached for, by every service method, because every service in the fleet does it the
  same way and threading them through every constructor buys a seam nobody uses. There is
  no fourth; everything else is handed in. The rules that keep the three safe are in
  `references/composition-and-lifecycle.md`.
- **The composition root is `internal/routes.SetupRouter`, not `main`.** One function
  still holds the whole object graph, which is the property `backend-shape` asks for; it
  just lives beside the route table it feeds. `main` owns the process lifecycle instead.
- **Models live in `database/model/`, not in the feature folder.** A table outlives the
  resource that created it and is read by several; `references/layout-and-naming.md`
  says why that beats one resource owning it.

Where `backend-shape` and this file disagree on anything else, this file has a gap. Say so
rather than picking one silently.

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
- **Order is part of the change.** The lifecycle refactor in particular has a required
  sequence (the pre-deploy migration job must be proven on a real deploy before boot-time
  migration is removed). `references/layout-and-naming.md` and
  `references/composition-and-lifecycle.md` each end with their refactor order. Do not
  reorder it.
- **Say what you are not doing.** The parts left in the old shape are a deliberate boundary.
  Unstated, they read as an abandoned job, and the next person re-litigates a decision you
  already made.
- **The existing shape still gets a hearing.** Where the project already solves something
  better than this blueprint does, say so and keep theirs. Being asked for a standard is not
  being asked to stop thinking.

## The stack

Gin for HTTP. GORM with `gorm.io/driver/postgres` for data. logrus behind
`pkg/logger`. godotenv for local `.env` files. `golang-jwt/jwt/v5` for user tokens.
swaggo for API docs. `go-redis` only when a service has a Pattern C queue. A dependency
outside this list is a decision someone states in the PR, with the reason the list did not
cover it.

## The spine

The non-negotiables, on one screen. The references explain how; this is the checklist.

- **One layout, every service.** `cmd/` (the HTTP process, `migration/`, an optional
  `worker/`), `database/` (`pgsql.go`, `db_migrate.go`, `database_seed/`, `model/`),
  `internal/` (`config`, `contracts`, `helpers`, `middleware`, `resources`, `routes`),
  `pkg/`. A reader who has opened one service can find anything in the next.
- **One folder per resource.** `internal/resources/<name>_resource/` holds `dto/`,
  `<name>.handler.go`, `<name>.service.go`, `<name>.helper.go`. Everything that changes
  when the resource changes lives in it, except its model.
- **One naming scheme.** `<Name>HandlerImpl`, `<Name>ServiceImpl`,
  `New<Name><Layer>(deps...) (*<Name><Layer>Impl, error)`. A nil dependency is a
  construction error.
- **Three globals, no fourth.** `database.Db`, `config.GlobalConfig`, `logger.Logger`,
  each assigned once at boot and never reassigned. Every client, service, handler and
  worker is constructed in `SetupRouter` and handed in.
- **`SetupRouter` is the composition root.** Clients, then services, then handlers, then
  routes, in dependency order. A construction error panics at boot, naming the resource.
  It starts nothing: background workers are returned to `main`.
- **`main` owns the process.** `LoadConfig` first, global middleware, `LoadDatabase`,
  `SetupRouter`, `signal.NotifyContext`, a bounded `server.Shutdown`, workers stopped in
  reverse, `CloseDatabase` last. No other package registers a signal handler or calls
  `os.Exit`.
- **Migrations run only in `cmd/migration`, as a pre-deploy job.** `MigrateDB` does
  renames, then `AutoMigrate`, then idempotent raw SQL; seeds and backfills run after it,
  in the same job. Never on boot, never behind a flag, and never "continue anyway".
- **Config is read once at boot into a typed struct.** Required-and-missing panics,
  naming the key. A secret never has a default; a peer URL never defaults to production.
  `os.Getenv` inside a call path is a hidden input.
- **Layers do only their job.** The handler knows Gin and parses, validates, delegates,
  responds. The service knows the business and the database and never imports Gin. A
  branch in a handler is a business rule that exists in exactly one entry point.
- **Typed DTOs at every boundary**: Create (values, `binding:"required"`), Update
  (pointers, nil means no change), Response, Query (`form` tags). A model never reaches
  the wire. `map[string]interface{}` crossing a boundary is a contract no compiler can
  check.
- **Identity comes from the credential.** User-facing routes read the tenant from the JWT
  and their DTOs have no tenant field. Routes that take a tenant in the path live under
  `InternalServicesAuth` and nowhere else.
- **Every query is tenant-scoped through one function.** `TenantScope` / `AccountScope`
  refuse a zero id, so an unscoped query fails loudly instead of matching every tenant.
- **One response envelope.** `{message, data}`, with `pagination` beside `data` on lists.
  Success and failure, every endpoint, the probes included.
- **One function maps an error to a response.** Services return sentinels declared in
  `internal/contracts/errors.go`, each with a kind and a sentence written for the user.
  `RespondServiceError` turns the kind into a status. No `err.Error()` on the wire, no
  string-matching to decide what is safe, no blanket 400.
- **Every list paginates through `ExecutePaginatedQuery`** and leaves through
  `RespondPaginated`. No exceptions, no "this table is small", no handler raising the
  ceiling.
- **Every database call is inside `SafeDBQuery` or `SafeDBTransaction`**, and its error is
  returned. Inside a transaction every statement uses `tx`, and nothing slow runs there.
- **Background work is Pattern A, B or C, chosen by what a lost run costs.** A goes through
  `concurrency.Go` after the commit; B is a `worker.Ticker` owned by `main`; C is a worker
  binary with a sweeper and a bounded-retry queue. Nothing runs without a deadline, a
  recover, and an owner.

## References

The concrete patterns live in these files. Read `layout-and-naming.md` first; read each
of the others when you reach its layer, not all six up front.

| File | Read it when |
|---|---|
| `references/layout-and-naming.md` | Creating any file: the tree, file and package names, `Impl` and constructor shape, the resource folder, the four DTO kinds, where code goes |
| `references/composition-and-lifecycle.md` | Writing `cmd/main.go`, `config.go` or `SetupRouter`: the three globals, construction order, graceful shutdown, teardown order |
| `references/http-layer.md` | Routes, middleware, handlers, binding errors, the response envelope, the error contract and `RespondServiceError`, pagination, identity |
| `references/data-layer.md` | `pgsql.go`, models, `SafeDBQuery`, transactions, upserts, `MigrateDB` and `cmd/migration`, seeds, tenant scoping, locking |
| `references/background-work.md` | Any work that is not a request: patterns A, B and C, the ticker, the queue, job identity, retries, cluster locks |
| `references/inter-service.md` | Calling another service or a vendor: typed clients, reading the peer's handler, timeouts, tenancy passthrough, ownership, adapters, webhooks |

The table is the contract those files satisfy: those paths, those subjects, nothing
quietly relocated or merged. An index that drifts from its references is a lie told to
whoever trusted it, and one wrong entry retires the whole table. If you move a file or
fold one subject into another, this table changes in the same commit or it is already
wrong.

They are written to be built from, not cited. Every helper the standard names is defined
in one of them, so a fresh repository can be constructed from these six and nothing else.
Where one references another's work - the envelope, the error contract, the tenant scope,
the ticker - it names the file that owns it rather than restating it, because the
restatement is the copy that drifts.
