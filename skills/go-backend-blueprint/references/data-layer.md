# The data layer

Where SQL is allowed to exist, what happens when it explodes, and what a transaction
is permitted to hold open.

The spine says layers do only their job and no package-level handle exists. This is
the bottom layer: the only one that knows a driver is installed.

## Queries live here and nowhere else

A `QueryRowContext` in a handler is a layer breach. So is one in a decision function.
The rule is not tidiness.

```go
// ✘ The rule and the query, welded together in the service.
func (s *Service) Cancel(ctx context.Context, sc domain.Scope, id int64) error {
	var status string
	err := s.db.QueryRowContext(ctx,
		`select status from orders where tenant_id = $1 and id = $2`,
		sc.TenantID, id).Scan(&status)
	if err != nil {
		return err // and now sql.ErrNoRows is the client's problem
	}
	if status == "shipped" {
		return domain.ErrForbidden
	}
	_, err = s.db.ExecContext(ctx,
		`update orders set status = 'cancelled' where tenant_id = $1 and id = $2`,
		sc.TenantID, id)
	return err
}
```

That costs three things, none of them aesthetic:

- **The rule becomes untestable.** "You cannot cancel a shipped order" is one `if`.
  Testing that one `if` now needs a live database, a schema, and a fixture. So the
  test is slow; so the suite gets a `-short` flag; so the flag becomes the default on
  every branch that is in a hurry; so the rule is untested. The rule did not get
  harder to test - it got welded to something that is.
- **The second caller forks it.** Admin bulk-cancel needs the same rule over a set of
  ids, which is a different query, so it cannot call this function. It copies the
  `if`. Now the rule exists twice, and when a third status becomes uncancellable only
  one copy learns.
- **The driver's error goes straight up.** `sql.ErrNoRows` is not a domain concept and
  the layer above does not know what to do with it, so it does the wrong thing: a
  missing order becomes a 500.

```go
// ✔ The store queries. The rule decides. Neither knows the other's job.
func (s *Service) Cancel(ctx context.Context, sc domain.Scope, id int64) error {
	o, err := s.store.Find(ctx, sc, id)
	if err != nil {
		return err // already a domain error; see Translate below
	}
	if err := cancellable(o); err != nil {
		return err
	}
	return s.tx(ctx, func(tx *sql.Tx) error {
		return s.store.Cancel(ctx, tx, sc, o.ID)
	})
}

// cancellable is the whole rule. It takes no dependencies, so its test is a table of
// orders and expected errors that runs in a millisecond - which is why it gets run,
// and why the bulk endpoint can call it too.
func cancellable(o Order) error {
	switch o.Status {
	case StatusShipped, StatusRefunded:
		return fmt.Errorf("%w: order is %s", domain.ErrForbidden, o.Status)
	}
	return nil
}
```

```go
// internal/order/store.go

// The Go check is for the message. The where clause is for the truth.
//
// cancellable ran against a row the service read a moment ago. Between that read and
// this update, the warehouse marked the order shipped. Without the predicate below
// you cancel a shipped order and refund a parcel that is on a van. The predicate
// makes the database the arbiter and RowsAffected the answer, and it costs nothing.
func (s *Store) Cancel(ctx context.Context, db dbx.DB, sc domain.Scope, id int64) error {
	if err := sc.Validate(); err != nil {
		return err
	}
	return dbx.SafeDBQuery(ctx, "order.Cancel", func() error {
		const q = `
			update orders
			   set status = 'cancelled', updated_at = now()
			 where tenant_id = $1
			   and id = $2
			   and status not in ('shipped', 'refunded')`

		res, err := db.ExecContext(ctx, q, sc.TenantID, id)
		if err != nil {
			return err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return err
		}
		if n == 0 {
			// Zero rows is not success. Ignoring RowsAffected here is how an update
			// that matched nothing returns nil and the caller reports "cancelled" for
			// an order that shipped.
			return fmt.Errorf("%w: order is no longer cancellable", domain.ErrConflict)
		}
		return nil
	})
}
```

The store takes `db dbx.DB` rather than reaching for its own handle, because this
write has to be able to join a transaction its caller opened:

```go
// internal/dbx/dbx.go
package dbx

// DB is what a store needs and nothing more. *sql.DB and *sql.Tx both satisfy it, so
// one method serves the caller inside a transaction and the caller outside one.
//
// The alternative is Insert and InsertTx, which is two implementations of one
// statement. They drift - one gains a column, the other does not - and the one that
// silently opens its own transaction is the one somebody calls from inside another.
type DB interface {
	ExecContext(ctx context.Context, q string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, q string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, q string, args ...any) *sql.Row
}
```

**A store method takes a handle when it must be able to join a unit its caller
opened. Otherwise it uses its own.** `Insert` takes one, because the order row and
its outbox row are one fact. `ExpireOlderThan` does not, because it is the entire
unit by itself and nothing else belongs in it.

## `SafeDBQuery`: a panic becomes an error

Every query in this service goes through it. It runs the call, converts the driver's
error into this service's vocabulary, and turns a panic into a returned error instead
of letting it unwind.

```go
// internal/dbx/safe.go
package dbx

import (
	"context"
	"fmt"
	"runtime/debug"

	"example.internal/svc/internal/domain"
)

// SafeDBQuery is the boundary between the driver's world and this service's. Above
// this line nothing knows what a pgconn.PgError is, and nothing has to.
//
// op is the query's name and it is not decoration: it is the only thing the log has
// to identify which of forty queries went wrong, because the stack above a recover
// is gone and the SQL is not going in a log line.
func SafeDBQuery(ctx context.Context, op string, fn func() error) (err error) {
	defer func() {
		rec := recover()
		if rec == nil {
			return
		}
		// The named return is the whole mechanism. recover() alone stops the unwind
		// and the function returns its zero values - so without this assignment a
		// panicking query returns a nil error, and the caller carries on believing
		// the write succeeded. That is strictly worse than the panic was.
		err = &PanicError{Op: op, Value: rec, Stack: debug.Stack()}
	}()

	return Translate(op, fn())
}

// PanicError is a recovered panic, converted. It satisfies
// errors.Is(err, domain.ErrInternal), so the status map in
// references/http-layer.md already answers 500 for it and never learns this type
// exists.
type PanicError struct {
	Op    string
	Value any
	Stack []byte
}

// The stack is IN the message, not beside it. The frames it names are gone by the
// time anything above the recover runs, and the two places in this service that log
// an error - the request line in references/http-layer.md and runOnce in
// references/background-work.md - both log err.Error(). A stack held in a field
// nobody reads is a stack you did not capture.
func (e *PanicError) Error() string {
	return fmt.Sprintf("panic in %s: %v\n%s", e.Op, e.Value, e.Stack)
}

func (e *PanicError) Is(target error) bool { return target == domain.ErrInternal }
```

**Why a query needs its own panic boundary when two recoveries already exist.** The
HTTP layer recovers per request and the Worker recovers per tick. Both are backstops
for the process, and both are too coarse to be the answer here.

`runOnce` recovers around a whole *batch*. A nil map in a row scanner on message 3 of
32 unwinds past `handleOne`, so messages 4 through 32 are never handled: not acked,
not retried, not dead-lettered. They sit in `state = 'running'` until the stale-claim
reaper returns them, minutes later, and the same poison message kills the same batch
again. One bad row stops the queue. With `SafeDBQuery`, the panic is an error inside
`handleOne`, message 3 gets its retry and eventually its dead-letter entry, and the
other 31 go through.

A panic here is not exotic. A nil pointer in a scan helper, a slice index in a row
mapper, a driver bug on a malformed value - each is a normal bug, and none of them
deserve to be an outage.

### What SafeDBQuery is not

It is not a way to ignore errors. "Safe" is about the panic and only about the panic.

```go
// ✘ The name said safe.
func (s *Store) Find(ctx context.Context, sc domain.Scope, id int64) Order {
	var o Order
	dbx.SafeDBQuery(ctx, "order.Find", func() error {
		return scanOrder(s.db.QueryRowContext(ctx, findQ, sc.TenantID, id), &o)
	})
	return o
}
```

That returns `Order{}` - id 0, tenant 0, total 0, status "" - on a connection reset,
a timeout, a missing row, and a panic, and the caller has no way to tell any of them
from an order that genuinely costs nothing. The 500 you did not raise becomes a
receipt for zero dollars and a shipped parcel. **Every `SafeDBQuery` call site
returns its error.** If a linter can enforce one thing in this repo, enforce that.

```go
// ✔
func (s *Store) Find(ctx context.Context, sc domain.Scope, id int64) (Order, error) {
	if err := sc.Validate(); err != nil {
		return Order{}, err
	}
	var o Order
	err := dbx.SafeDBQuery(ctx, "order.Find", func() error {
		const q = `
			select id, tenant_id, customer_id, total_cents, status, created_at
			  from orders
			 where tenant_id = $1 and id = $2`
		return scanOrder(s.db.QueryRowContext(ctx, q, sc.TenantID, id), &o)
	})
	return o, err
}
```

It also does not log. That is deliberate twice over. A store is constructed
`NewStore(db)` and holds no logger, because state a constructor does not name is
state a test cannot replace. And this service already has exactly one place per entry
point that logs a failure - the request line, and `runOnce`. A log call here would
emit a second line for every failure those two already report, and a doubled error
count is an error count nobody can alert on. The panic still reaches the log with its
op and its full stack, because `SafeDBQuery` put both in the error at the only moment
either still existed.

### Driver errors become domain errors, here, once

This is the translation that makes file `references/http-layer.md`'s single status
map possible. Without it, "not found" is a driver sentinel that every handler has to
recognise separately, and a unique violation is a 500.

```go
// internal/dbx/errors.go
package dbx

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5/pgconn"

	"example.internal/svc/internal/domain"
)

// Translate is the ONLY function in this service that knows a driver exists. That is
// the point: grep for pgconn and you get this file, so swapping a driver is a change
// to one function rather than an archaeology project across forty handlers.
func Translate(op string, err error) error {
	if err == nil {
		return nil
	}

	switch {
	case errors.Is(err, sql.ErrNoRows):
		// The single most common one. A store that leaks sql.ErrNoRows upwards makes
		// every caller import database/sql to ask "did it exist" - and the one that
		// forgets returns a 500 for a typo in a URL.
		return fmt.Errorf("%s: %w", op, domain.ErrNotFound)

	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		// Not a database failure. The client hung up, or shutdown started. Classifying
		// it as internal pages you for every deploy and for every user who closed a
		// tab, and then nobody reads the page.
		return fmt.Errorf("%s: %w", op, err)
	}

	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		switch pg.Code {
		case "23505": // unique_violation
			// The constraint name goes in the message, which goes to the log. It does
			// NOT go to the client: statusFor returns a fixed string for ErrConflict,
			// which is what stops "users_tenant_id_email_key" from telling an
			// attacker your table name, your uniqueness rule, and that the address
			// they guessed is registered.
			return fmt.Errorf("%s: %w (constraint %s)", op, domain.ErrConflict, pg.ConstraintName)

		case "23503": // foreign_key_violation
			return fmt.Errorf("%s: %w (constraint %s)", op, domain.ErrConflict, pg.ConstraintName)

		case "23502", "23514": // not_null_violation, check_violation
			// The database caught what a DTO should have. It is a 400, because the
			// request was wrong - and it is also a hole in Validate, and this log line
			// is how you find out which field.
			return fmt.Errorf("%s: %w (%s on %s)", op, domain.ErrInvalid, pg.Code, pg.ColumnName)

		case "40001", "40P01": // serialization_failure, deadlock_detected
			// Retryable, and only the caller knows whether retrying is safe. 503 says
			// "try again" to a client that can, and the log says which query is
			// fighting which.
			return fmt.Errorf("%s: %w (%s)", op, domain.ErrUnavailable, pg.Code)

		case "57014": // query_canceled, which is what a statement_timeout looks like
			return fmt.Errorf("%s: %w (statement timeout)", op, domain.ErrUnavailable)
		}
	}

	// Unclassified is internal. The driver's own text is wrapped in, so the log has
	// everything; the client gets statusFor's fixed "internal error" and learns
	// nothing about your schema.
	return fmt.Errorf("%s: %w: %v", op, domain.ErrInternal, err)
}
```

Every code above is a decision someone has to make once. Leaving them unmapped is
also a decision: it makes all of them 500s, so a duplicate email pages you at 3am
with the same severity as a dead primary.

## Transactions: `s.tx`

**A transaction is a decision-layer concern with a data-layer helper.** The question
it answers - which facts must become true together, or not at all - is a business
question. The store sees one table and cannot answer it. So `tx` is an unexported
method on the service, and the store never begins one.

```go
// internal/order/service.go
package order

type Service struct {
	db    *sql.DB
	store *Store
	users *user.Store
	mail  *mailer.Client
	jobs  *Queue
	log   *slog.Logger
}

func NewService(
	db *sql.DB,
	store *Store,
	users *user.Store,
	mail *mailer.Client,
	jobs *Queue,
	log *slog.Logger,
) *Service {
	return &Service{db: db, store: store, users: users, mail: mail, jobs: jobs, log: log}
}

// tx begins, defers rollback, runs fn, commits. It is four moves and it is the only
// place in this feature that names BeginTx, so there is exactly one rollback policy
// and exactly one place to add a retry on serialization_failure later.
func (s *Service) tx(ctx context.Context, fn func(*sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}

	// Unconditional, and deferred. After a successful Commit this returns
	// sql.ErrTxDone and does nothing, which is exactly right. The version guarded by
	// `if err != nil { tx.Rollback() }` misses two paths: the early return somebody
	// adds to fn next year, and the panic - and a panic that unwinds past an open
	// transaction leaves it holding its locks until the connection is reaped.
	defer func() {
		if rerr := tx.Rollback(); rerr != nil && !errors.Is(rerr, sql.ErrTxDone) {
			// Logged, not returned. err already names the real failure; replacing it
			// with the rollback's failure hides the cause behind its consequence.
			s.log.Error("rollback failed", "err", rerr)
		}
	}()

	if err := fn(tx); err != nil {
		return err // already a domain error: fn's callees went through SafeDBQuery
	}
	// Commit is a write and it can fail on its own - a deadlock, a lost connection,
	// a disk. A tx helper that ignores this return reports success for a transaction
	// that rolled back, which is the most expensive lie in this file.
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}
```

Used, with the store taking the handle it was given:

```go
func (s *Service) Create(ctx context.Context, in CreateOrder) (Order, error) {
	var out Order
	err := s.tx(ctx, func(tx *sql.Tx) error {
		var err error
		out, err = s.store.Insert(ctx, tx, in)
		return err
	})
	if err != nil {
		return Order{}, err
	}
	return out, nil
}
```

`fn` writes to a variable in the enclosing scope rather than returning a value,
because `tx` has to be able to run `fn` and then fail at `Commit`. If `tx` returned
`fn`'s value, a caller would have a fully-populated `Order` and a commit error at the
same time, and one of the two would get used.

### Nothing that can be slow goes inside one

**No network call. No queue publish to another system. No third-party API. No
`time.Sleep`.** Not "avoid where practical" - none.

```go
// ✘
err := s.tx(ctx, func(tx *sql.Tx) error {
	out, err := s.store.Insert(ctx, tx, in)
	if err != nil {
		return err
	}
	return s.mail.SendReceipt(ctx, out) // 10s timeout, someone else's uptime
})
```

Trace it when the mailer is having a bad afternoon. Each request holds one pooled
connection and one open transaction for ten seconds. `openDB` set
`SetMaxOpenConns(cfg.MaxDBConns)`, so at twenty concurrent creates the pool is empty
and **every other endpoint in the service blocks on `BeginTx`** - including the ones
that never touch orders, never touch the mailer, and were working perfectly. You have
imported a third party's outage and amplified it into a total one.

That is only the first half. Each of those transactions holds its row locks for ten
seconds, so concurrent writers to the same order queue behind it. And each sits
`idle in transaction`, which pins the database's oldest running transaction, which
stops autovacuum from cleaning up dead tuples anywhere in the database. A slow mailer
becomes table bloat on tables it has never heard of.

The two correct shapes are the outbox and start-after-commit. Both are in
`references/background-work.md`; the rule they encode is that the only thing allowed
inside a transaction is more of the same database.

## Idempotent writes

**Read-then-write is a race with itself.**

```go
// ✘ Correct in a single-threaded test. Wrong the moment there are two of anything.
func (s *Store) EnsureCustomer(
	ctx context.Context,
	db dbx.DB,
	sc domain.Scope,
	email, name string,
) (int64, error) {
	var id int64
	err := db.QueryRowContext(ctx,
		`select id from customers where tenant_id = $1 and lower(email) = lower($2)`,
		sc.TenantID, email).Scan(&id)
	if err == nil {
		return id, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	// The window is right here, and it is wide enough. The other replica ran the same
	// select against the same rows and also got no rows, because the row does not
	// exist yet for either of you. Both of you now insert.
	return 0, db.QueryRowContext(ctx,
		`insert into customers (tenant_id, email, name) values ($1, $2, $3) returning id`,
		sc.TenantID, email, name).Scan(&id)
}
```

The window does not need replicas. Two goroutines in one process is enough, and a
retried request is enough: the client's first attempt timed out at the load balancer
while the insert was still running, so the retry arrives while attempt one is between
its select and its insert. This is not a rare interleaving - it is what a retry
storm is made of, and a retry storm is exactly when it happens.

What happens next depends entirely on whether the constraint exists:

- **With a unique index**, one insert wins and the other gets `23505`, which
  `Translate` turns into `ErrConflict` and the client sees a 409 for a request that
  should have succeeded. Annoying, recoverable, visible.
- **Without one**, both succeed. You now have two customers with the same email in
  the same tenant, forever. Every `QueryRow` that expects one row gets an arbitrary
  one of the two. Half the orders attach to the first, half to the second. Nothing
  errors, nothing logs, and you find out when a report disagrees with itself.

```sql
-- The correctness boundary. Not the Go code above it.
--
-- lower(email) is in the index because the uniqueness rule is case-insensitive. A
-- plain unique on (tenant_id, email) lets Alice@ and alice@ both exist, and then
-- your login is a coin flip.
create unique index customers_tenant_email
    on customers (tenant_id, lower(email));
```

```go
// ✔ One statement. One round trip. No window to lose.
func (s *Store) EnsureCustomer(
	ctx context.Context,
	db dbx.DB,
	sc domain.Scope,
	email, name string,
) (int64, error) {
	if err := sc.Validate(); err != nil {
		return 0, err
	}
	var id int64
	err := dbx.SafeDBQuery(ctx, "customer.Ensure", func() error {
		// The conflict target must match a real unique index, expression and all. It
		// is not a hint: Postgres answers a mismatch with "there is no unique or
		// exclusion constraint matching the ON CONFLICT specification", at runtime,
		// on the first duplicate - which is the first time anyone runs this path
		// twice, which is production.
		const q = `
			insert into customers (tenant_id, email, name, updated_at)
			values ($1, $2, $3, now())
			on conflict (tenant_id, lower(email)) do update
			   set name = excluded.name,
			       updated_at = now()
			returning id`

		return db.QueryRowContext(ctx, q, sc.TenantID, email, name).Scan(&id)
	})
	return id, err
}
```

**`do update`, not `do nothing`.** `on conflict do nothing returning id` returns no
row when it conflicts, so `Scan` gives you `sql.ErrNoRows`, which `Translate` turns
into `ErrNotFound` - a 404 for a row that definitely exists, on the exact path the
upsert was written to handle. If there is genuinely nothing to update, update
something inert: `do update set updated_at = excluded.updated_at`. The row comes back
and the bug never gets written.

**The constraint is the correctness boundary; the application check is an
optimisation.** A `select` before an `insert` is allowed - it saves a round trip on
the common path, it produces a better error message, it is fine. What it is not is a
guarantee. Two processes can both pass any check written in Go, and the only thing
that has ever stopped them is a unique index. If the invariant matters and there is
no constraint for it, the invariant does not exist yet. Write the index first.

The same shape covers at-least-once delivery: `references/background-work.md` makes
every consumer's handler idempotent because the ack is a separate write from the
work. `on conflict do update` is how a handler that runs twice produces one row.

## One migration mechanism, and one place that runs it

**Two mechanisms is two truths about the schema.** A tool for tables and a hand-run
psql script for indexes means the answer to "what is the schema" is a merge of two
sources, and the merge only exists in one person's head. Auto-creating tables from
struct tags *plus* a file of SQL for the things the tags could not express is the
same failure wearing a nicer hat: the tags win on some columns, the SQL wins on
others, and nobody can tell you which without running it.

**And it runs in exactly one place: a separate command, once per deploy, before any
replica boots.**

```go
// cmd/migrate/main.go
package main

// A second binary in the same image. Same code, same schema files, same version -
// which is what makes "the migration that ran" and "the code that is running" the
// same commit, provably, instead of by convention.
func main() {
	if err := run(); err != nil {
		slog.Error("migrate failed", "err", err)
		os.Exit(1) // the deploy stops here, before a single replica starts
	}
}

func run() error {
	cfg := config.Load()
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel}))

	db, err := sql.Open("pgx", cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	return migrate.Up(ctx, db, log)
}
```

### What every-replica-migrates costs

Calling `migrate.Up` from `run` looks tidy and free. It is neither.

- **Ten replicas roll at once and ten processes migrate.** The first takes an
  `ACCESS EXCLUSIVE` lock for its `alter table`. The other nine block on it - not on
  the lock they will need later, on this one, right now - so nine replicas sit past
  their startup probe deadline, get killed, restart, and block again. The rollout
  stalls and the logs say nothing except that the pods are not ready.
- **The one that loses the race crashes.** Whichever replica applies
  `create index ... ` second gets "already exists", `run` returns an error, `main`
  exits 1, and the orchestrator restarts it into the same error. That is a crash
  loop caused by a migration that succeeded.
- **A failed migration takes the service with it.** The schema change was wrong;
  every replica now refuses to boot. Without the split, you have no running service
  and a schema in an unknown state. With it, the migration job fails, the old
  replicas keep serving the old schema, and the deploy never started.
- **Nothing can be gated on it.** A separate command has an exit code the deploy can
  wait for. A migration inside `run` completes at some point during the rollout,
  which means the new code is live against the old schema for a window nobody
  measured.

### The runner

```go
// internal/migrate/migrate.go
package migrate

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"io/fs"
	"log/slog"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Embedded, not read from disk. A migration directory that is not in the binary is a
// file that can be missing from the image, and you find that out during the deploy
// it was needed for.
//
//go:embed sql/*.sql
var files embed.FS

// Up applies every file that is not in the ledger, in name order, and does nothing
// else. It is called from cmd/migrate and from nowhere else: not from run, not from
// an init, not from a test helper that "just needs the schema".
func Up(ctx context.Context, db *sql.DB, log *slog.Logger) error {
	conn, err := db.Conn(ctx)
	if err != nil {
		return fmt.Errorf("conn: %w", err)
	}
	defer conn.Close()

	// Blocking, unlike the try-lock in references/background-work.md - and the
	// difference is the point. There, a second replica has nothing to add and should
	// leave. Here it has to wait: the deploy is gated on this process's exit code, so
	// exiting 0 without the migration applied is a lie the rollout believes.
	//
	// The deploy is supposed to run this once. "Supposed to" is not a mechanism.
	const lockID = 823144115
	if _, err := conn.ExecContext(ctx, `select pg_advisory_lock($1)`, lockID); err != nil {
		return fmt.Errorf("lock: %w", err)
	}
	defer func() {
		uctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := conn.ExecContext(uctx, `select pg_advisory_unlock($1)`, lockID); err != nil {
			log.Error("advisory unlock failed", "err", err)
		}
	}()

	if _, err := conn.ExecContext(ctx, `
		create table if not exists schema_migrations (
		    version    text        primary key,
		    applied_at timestamptz not null default now()
		)`); err != nil {
		return fmt.Errorf("ensure ledger: %w", err)
	}

	applied, err := ledger(ctx, conn)
	if err != nil {
		return err
	}

	names, err := fs.Glob(files, "sql/*.sql")
	if err != nil {
		return err
	}
	// Lexical order IS the order, which is why every file is 0001_, 0002_,
	// zero-padded. A timestamp prefix orders by whichever laptop's clock produced it,
	// so two branches that merge cleanly apply in an order neither author intended -
	// and it works on their machines, where each one applied alone.
	sort.Strings(names)

	for _, name := range names {
		version := filepath.Base(name)
		if applied[version] {
			continue
		}
		body, err := files.ReadFile(name)
		if err != nil {
			return err
		}

		if strings.HasSuffix(version, ".notx.sql") {
			err = applyNoTx(ctx, conn, version, string(body))
		} else {
			err = applyTx(ctx, conn, version, string(body))
		}
		if err != nil {
			return err
		}
		log.Info("migration applied", "version", version)
	}
	return nil
}

func ledger(ctx context.Context, conn *sql.Conn) (map[string]bool, error) {
	rows, err := conn.QueryContext(ctx, `select version from schema_migrations`)
	if err != nil {
		return nil, fmt.Errorf("read ledger: %w", err)
	}
	defer rows.Close()

	applied := map[string]bool{}
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		applied[v] = true
	}
	return applied, rows.Err()
}

// applyTx puts the migration and its ledger row in ONE transaction. They commit
// together or neither does. A migration that ran but was not recorded runs again on
// the next deploy, and the second `alter table ... add column` fails, and now the
// deploy is wedged on a migration that already succeeded and a human has to hand-edit
// a ledger at 2am.
func applyTx(ctx context.Context, conn *sql.Conn, version, body string) error {
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, body); err != nil {
		return fmt.Errorf("apply %s: %w", version, err)
	}
	if _, err := tx.ExecContext(ctx,
		`insert into schema_migrations (version) values ($1)`, version); err != nil {
		return fmt.Errorf("record %s: %w", version, err)
	}
	return tx.Commit()
}

// A *.notx.sql file runs outside a transaction, because some statements cannot run
// inside one: `create index concurrently` fails with "CREATE INDEX CONCURRENTLY
// cannot run inside a transaction block", and a plain `create index` on a large hot
// table locks out writes for the whole build.
//
// This is still ONE mechanism - one ledger, one runner, one order, one suffix. A
// second tool for concurrent indexes would be a second truth about the schema.
//
// The cost is real and it is the price of the concurrency: nothing rolls back. Keep
// these files to a single statement, so "failed halfway" cannot happen, and a
// concurrent index that fails leaves an INVALID index you drop and retry.
func applyNoTx(ctx context.Context, conn *sql.Conn, version, body string) error {
	if _, err := conn.ExecContext(ctx, body); err != nil {
		return fmt.Errorf("apply %s: %w", version, err)
	}
	if _, err := conn.ExecContext(ctx,
		`insert into schema_migrations (version) values ($1)`, version); err != nil {
		return fmt.Errorf("record %s: %w", version, err)
	}
	return nil
}
```

```
internal/migrate/sql/
    0001_init.sql
    0002_orders_add_priority.sql
    0003_orders_customer_idx.notx.sql
```

**Migrations are forward-only and additive across a rollout.** During a rolling
deploy the old code runs against the new schema for as long as the rollout takes. A
migration that drops a column the old code still selects turns the deploy into an
outage for the half of the replicas that have not rolled yet. Adding a column is
safe; removing one is two deploys - stop writing it, ship, then drop it, ship. There
is no `Down`, because the rollback of a deploy is the previous image, and a `Down`
that has never been run against real data is a script you are trusting for the first
time during an incident.

## The pool is explicit at boot

`openDB` in `references/composition-and-lifecycle.md` sets four numbers. Every one of
them has a default, and **a default pool is a number nobody chose that you discover
under load.** What each one buys:

- **`SetMaxOpenConns`. Default: unlimited.** Unlimited means the service opens one
  connection per concurrent query until the server's `max_connections` refuses the
  next one - and it refuses it for every service on that server, not just yours, and
  for the psql session you were about to open to find out why. This number is your
  share of a global budget: `replicas × MaxDBConns`, summed over every service on
  that database, has to fit under `max_connections` with room left for the admin
  connection you will need during the incident. Nobody owns that sum, which is why it
  is the one that gets exceeded.
- **`SetMaxIdleConns`. Default: 2.** With `MaxOpen` at 20 and `MaxIdle` at 2, a burst
  opens 18 connections and then closes 18 connections, and the next burst opens them
  again. You pay a TCP handshake, a TLS negotiation, and an auth round trip per query
  at exactly the moment you are busiest. Set it equal to `MaxOpen`: a pool that grew
  under load should stay grown, and `SetConnMaxIdleTime` is what shrinks it when the
  load is genuinely gone.
- **`SetConnMaxLifetime`. Default: forever.** A connection that never dies outlives
  every proxy, pooler, and load balancer in front of it. After a failover your pool
  is still holding connections to the old primary - which is now a replica - and
  every write returns "cannot execute INSERT in a read-only transaction" until
  somebody restarts the process. Same shape with a connection pooler in the path: it
  reconfigures, your connections do not, and you are pinned to a backend that no
  longer exists. Thirty minutes bounds every one of those to thirty minutes.
- **`SetConnMaxIdleTime`. Default: forever.** Returns the connections a burst grew
  once the burst is over, so a 3am traffic spike does not hold your whole quota until
  the next deploy.

`sql.Open` does not dial. `openDB` pings, under a timeout, and that ping is what
turns a wrong password into a failed deploy instead of a 500 on somebody's first
request.

## Tenancy is a parameter, then a constraint

**A query missing its tenant scope is not a bug. It is a data breach.** It ships
green, passes every test written by someone with one tenant in their fixture, and the
first report is from a customer reading another customer's orders.

So it does not get to be a thing you remember.

```go
// internal/domain/scope.go
package domain

import "fmt"

// Scope is the tenant boundary as a TYPE. Every store method that touches a
// tenant-owned table takes one.
//
// This is not a convention and it is not a review checklist item. A missing
// `and tenant_id = $1` looks exactly like every other line of SQL and a reviewer's
// eye slides off it. A missing Scope PARAMETER does not compile.
type Scope struct {
	TenantID int64
}

// Validate is the first line of every store method. Scope{} is constructible - Go
// has no way to stop that - and Scope{}.TenantID is 0, which matches no rows until
// the day a backfill inserts a row with a zero default and then matches all of them.
// Refuse it at the one place every query already passes through.
func (s Scope) Validate() error {
	if s.TenantID <= 0 {
		return fmt.Errorf("%w: query has no tenant scope", ErrInternal)
	}
	return nil
}
```

Be honest about what the type does and does not buy. It forces the store method to
**have** the tenant. It cannot force the `where` clause to use it - a `Scope`
parameter that never appears in the query compiles fine. What it changes is that the
omission is now visible: a reviewer looking at a method whose signature says `sc
domain.Scope` and whose SQL never says `tenant_id` is looking at a one-line diff, not
at the absence of a line.

**The line that cannot be reviewed away is in the schema.**

```sql
create table customers (
    tenant_id  bigint not null,
    id         bigint generated always as identity,
    email      text   not null,
    name       text   not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    -- The tenant leads the key. Not beside it, in it.
    primary key (tenant_id, id),
    unique (tenant_id, id)
);

create table orders (
    tenant_id   bigint not null,
    id          bigint generated always as identity,
    customer_id bigint not null,
    total_cents bigint not null check (total_cents >= 0),
    status      text   not null,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),

    primary key (tenant_id, id),

    -- The composite foreign key is the whole trick. With `references customers (id)`
    -- an order in tenant 7 can point at a customer in tenant 9 - the database will
    -- happily let you - and then a join that looks perfectly scoped
    -- (`where o.tenant_id = $1`) returns tenant 9's customer name through the join.
    -- You scoped the query and leaked anyway. With this key, that row cannot be
    -- inserted at all.
    foreign key (tenant_id, customer_id) references customers (tenant_id, id)
);

-- Every index leads with tenant_id. An index on (created_at) alone is an index the
-- planner uses for a tenant-scoped list by scanning other tenants' rows and throwing
-- them away - correct, and slower for every tenant as any one tenant grows.
create index orders_tenant_created on orders (tenant_id, created_at desc, id desc);
```

That last index is `ExecutePaginatedQuery`'s ordering, in the schema:
`(tenant_id, created_at desc, id desc)` is the `where` column, the sort column, and
the tiebreak, in the order the query names them. An index that stops at `created_at`
makes the tiebreak a sort, and the sort is the thing that turns a 25-row page into a
read of every order the tenant has.

## Checklist

A data-layer change is done when all of these are true. Any "no" is the bug you ship.

- The SQL is in a store method. Not in a handler, not in a decision function.
- The store method takes `domain.Scope` and calls `sc.Validate()` first.
- The `where` clause names `tenant_id`, and the index it uses leads with it.
- The query is inside `SafeDBQuery`, and the call site returns its error.
- Nothing above `dbx` mentions `pgconn`, `sql.ErrNoRows`, or an SQLSTATE.
- A new failure mode has a case in `Translate` and a sentinel in `domain`.
- `RowsAffected` is checked on every `update` and `delete` whose zero is a failure.
- A transaction is opened by `s.tx` in the service, never by a store.
- Nothing inside the transaction talks to anything but this database.
- A write that can be retried is an upsert against a real unique index, not a select
  followed by an insert.
- The schema change is one numbered file, additive, applied by `cmd/migrate`.
- The invariant you are relying on exists as a constraint, not as an `if` in Go.
