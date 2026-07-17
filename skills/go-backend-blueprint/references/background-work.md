# Background work

Anything this process does that no request is waiting for: ticks, queues, retries,
schedules. All of it wears one shape.

The spine says bare goroutines are banned and every job is a Worker. This is the
Worker, and the rules that decide what goes in one.

## The four failures in `go doSomething()`

```go
// ✘ In a handler.
func (h *OrderHandler) Create(w http.ResponseWriter, r *http.Request) {
	order, err := h.svc.Create(r.Context(), in)
	if err != nil {
		writeErr(w, err)
		return
	}
	go h.mailer.SendReceipt(r.Context(), order)
	writeJSON(w, http.StatusCreated, order)
}
```

**No lifecycle.** Shutdown cancels the root context, `run` returns, the process
exits, and this send is halfway through a socket write. Nobody waits for it and
nobody logs it. The receipt is lost - silently, on every deploy, and deploys are
exactly when traffic is being drained, so you lose a burst of them at once.

**No context that works.** The line above passes `r.Context()`, which the `net/http`
server cancels the instant `Create` returns. The send is cancelled essentially
always, and it reads as a flaky mailer for as long as you are willing to look at it.
The obvious fix is the opposite bug:

```go
go h.mailer.SendReceipt(context.Background(), order) // ✘ no deadline, ever
```

Now a hung host holds this goroutine and its connection forever. Ten thousand of
those is the memory graph you get paged for, and the mailer is fine by the time you
look.

**No retry, no dedupe.** One 500 from the mailer and the receipt is gone with no
record it was attempted. One double-clicked button and it is sent twice. There is
no row anywhere to reconcile against, because the job only ever existed as a stack
frame.

**No observability, and the panic is fatal.** An unrecovered panic in any goroutine
takes the whole process down, including every unrelated request in flight. The
stack names the mailer, not the order that triggered it, so the trace tells you
where it died and nothing about why.

Every one of those is fixed once, in the Worker, instead of forgotten separately at
each of the fourteen places someone typed `go`.

## Choose the weakest mechanism that meets the bar

One question decides it: **what happens if this work never runs?**

| Answer | Mechanism |
|---|---|
| Nothing anyone notices, or the next run fixes it | fire-and-forget, in a Worker |
| Someone notices within the hour; one instance keeps up | in-process ticker Worker |
| Money, a legal duty, or a promise to a third party | durable queue + consumer |

- **Fire-and-forget** still means a Worker: owned, bounded, logged. The tolerance is
  for loss, not for lawlessness. Refreshing a cache, warming an index, emitting a
  gauge.
- **In-process ticker** reads its work from the database it already has. No new
  infrastructure, no broker, no schema. Expiring stale rows, a nightly rollup,
  reconciling a counter. If you run replicas, it needs a lock - see the last
  section.
- **Durable queue** is for work that must survive the process that created it, and
  the process that created it is restarted on every deploy. Payment capture,
  webhook delivery, sending the receipt someone paid for.

**The rule: choose by what loss costs, not by what is interesting to build.** A
durable queue for a cache refresh buys a broker to operate, a schema to migrate, a
dead-letter table to watch and a new outage mode, in exchange for a guarantee
nobody asked for. Fire-and-forget for a payment buys a silent hole in the ledger
that reconciliation finds in a quarter, if you have reconciliation.

Move up a tier when the answer changes, not before. Every tier costs someone's
attention forever.

## The unified Worker

One type. Every background job in the service is one of these, so a reader who has
read one has read them all, and there is exactly one place to add a metric.

```go
// internal/worker/worker.go
package worker

import (
	"context"
	"errors"
	"log/slog"
	"runtime/debug"
	"time"
)

// Job is the only thing a feature writes. Everything else in this file is
// identical for every job in the service, which is the entire point.
type Job func(ctx context.Context) error

type Worker struct {
	name  string
	every time.Duration
	job   Job
	log   *slog.Logger

	cancel context.CancelFunc
	done   chan struct{}
}

func New(name string, every time.Duration, log *slog.Logger, job Job) *Worker {
	return &Worker{
		name:  name,
		every: every,
		job:   job,
		log:   log.With("worker", name),
		done:  make(chan struct{}),
	}
}

// Start is non-blocking and is called exactly once, from the composition root.
// Not from a handler, not from a service, not from another worker: a goroutine
// whose owner is not the root is a goroutine nobody stops.
func (w *Worker) Start(ctx context.Context) {
	ctx, w.cancel = context.WithCancel(ctx)

	go func() {
		defer close(w.done)
		w.log.Info("worker started", "every", w.every)
		defer w.log.Info("worker stopped")

		t := time.NewTicker(w.every)
		defer t.Stop()

		for {
			// Check cancellation before working, not only after. A select over a
			// ready ticker and a done context picks at random, so without this a
			// cancelled worker runs one more tick about half the time - which is
			// how a "stopped" job writes rows after shutdown, unreproducibly, on
			// one deploy in six.
			select {
			case <-ctx.Done():
				return
			default:
			}

			w.runOnce(ctx)

			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
		}
	}()
}

// runOnce is the panic boundary. A panic in a job is a bug in that job; without
// this recover it is an outage in every unrelated endpoint the process serves.
func (w *Worker) runOnce(ctx context.Context) {
	defer func() {
		if r := recover(); r != nil {
			w.log.Error("worker panicked", "panic", r, "stack", string(debug.Stack()))
		}
	}()

	start := time.Now()
	err := w.job(ctx)

	switch {
	case err == nil:
		w.log.Debug("tick ok", "took", time.Since(start))
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		// Shutdown, not a failure. Logging it at error level teaches everyone to
		// ignore this worker's error logs, which is where the real one will be.
		w.log.Info("tick cancelled", "took", time.Since(start))
	default:
		w.log.Error("tick failed", "took", time.Since(start), "err", err)
	}
}

// Stop asks, then waits. Cancelling the context is the ask; the receive on done is
// the answer. A shutdown that only cancels is not a shutdown, it is a race you
// usually win.
//
// The timeout is not optional: a job that ignores its context would otherwise hold
// the process open until the orchestrator's SIGKILL, which arrives with the tick
// mid-write. Abandon it loudly so the log names the worker instead of leaving a
// bare exit code.
func (w *Worker) Stop(timeout time.Duration) {
	if w.cancel == nil {
		return // never started; Stop must be safe on the boot-failure path
	}
	w.cancel()

	select {
	case <-w.done:
	case <-time.After(timeout):
		w.log.Error("worker did not stop in time, abandoning", "timeout", timeout)
	}
}
```

The job itself carries no lifecycle at all. It is a method on the service that owns
the logic, which means it is callable from a test with no worker anywhere:

```go
// internal/order/service.go

// ExpireStale is a Job. It takes a context, it returns an error, it knows nothing
// about tickers. TestExpireStale calls it directly.
func (s *Service) ExpireStale(ctx context.Context) error {
	// Bound the unit of work even though the root context already bounds the
	// process. This one derives from ctx, so shutdown still cancels it AND a
	// wedged query cannot hold the tick open past its own tick interval.
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	n, err := s.store.ExpireOlderThan(ctx, time.Now().Add(-24*time.Hour))
	if err != nil {
		return fmt.Errorf("expire stale orders: %w", err)
	}
	if n > 0 {
		s.log.Info("expired stale orders", "count", n)
	}
	return nil
}
```

### A queue consumer is the same Worker

It is not a second shape. It is a Worker whose job drains a batch, which is why the
lifecycle, the panic boundary, the logging and the `Stop` semantics are the ones
above, unchanged.

```go
// NewConsumer returns a Worker. The interval is the IDLE poll interval: how long
// to wait when the queue was empty.
//
// Throughput ceiling is batch ÷ interval. 32 per 250ms is 128 jobs/sec per
// replica. If the backlog grows faster than that, raise the batch before you raise
// the replica count - replicas cost connections, the batch costs nothing.
func NewConsumer(name string, q Queue, h Handler, log *slog.Logger) *Worker {
	return New(name, 250*time.Millisecond, log, func(ctx context.Context) error {
		msgs, err := q.Claim(ctx, 32)
		if err != nil {
			return fmt.Errorf("claim: %w", err)
		}
		for _, m := range msgs {
			handleOne(ctx, q, h, m, log)
		}
		return nil
	})
}

type Handler func(ctx context.Context, m Message) error

type Message struct {
	ID      int64
	Key     string
	Payload []byte
	Attempt int
}

// Queue is what a consumer needs and nothing more: the worker package declares the
// interface it consumes, so a second implementation is a new file rather than an edit
// to this one.
//
// Enqueue is deliberately absent. It takes a transaction, and a consumer has no
// transaction to give it - so putting it here would force every implementation to
// answer a question only producers ask, and force the consumer's tests to stub a
// method they never call.
type Queue interface {
	Claim(ctx context.Context, n int) ([]Message, error)
	Ack(ctx context.Context, id int64) error
	Retry(ctx context.Context, id int64, runAfter time.Time) error
	DeadLetter(ctx context.Context, id int64, cause string) error
}

// Payload is what a producer enqueues: anything that can name itself and survive
// being JSON. Key is the only method because the unique index is the only thing the
// queue needs from the job it is storing.
type Payload interface {
	Key() string
}
```

## Start after commit, snapshot by value, always bounded

```go
// ✘ The job is enqueued inside the transaction, by a queue that cannot join it.
func (s *Service) Create(
	ctx context.Context,
	sc domain.Scope,
	in CreateOrder,
) (*Order, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	order, err := s.store.Insert(ctx, tx, sc, in)
	if err != nil {
		return nil, err
	}

	// The row is not committed. The consumer reads on its own connection, in its
	// own transaction, and sees nothing - so the job fails with "order not found"
	// for a row that is about to exist. Or it wins the race and works. Or the
	// commit below fails, the order never existed, and the customer has a receipt
	// for it anyway. All three are live; which you get is re-rolled every request.
	s.jobs.Enqueue(ctx, ReceiptJob{OrderID: order.ID})

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return order, nil
}
```

That line does not compile against the `Enqueue` this file declares, which demands the
`*sql.Tx`. That is the point, and it is worth being precise about why the shape exists
at all: a context and a payload, with no transaction, is exactly the signature you get
from a broker client, because a broker has no transaction to be given. So the bug is
not something a careless person types. It is the only thing that queue's API lets them
type, and the three outcomes above are what they get for using it.

Which is the argument for putting the queue in the same database as the rows it talks
about. A queue that can take your transaction can be made to demand it, and then the
compiler enforces the ordering on every call site, forever. A queue that cannot take
one leaves you enforcing it by review, on a race that reproduces about a third of the
time.

There are exactly two correct shapes.

**Enqueue inside the transaction, only when the queue is the same database.** Then
the job and the row commit together or vanish together, and no consumer can ever
see one without the other. That is the outbox, and it is the only way to enqueue
before commit:

```go
// ✔ Same database, one transaction, one atomic fact.
func (s *Service) Create(
	ctx context.Context,
	sc domain.Scope,
	in CreateOrder,
) (*Order, error) {
	var order *Order

	err := s.tx(ctx, func(tx *sql.Tx) error {
		var err error
		order, err = s.store.Insert(ctx, tx, sc, in)
		if err != nil {
			return err
		}
		return s.jobs.Enqueue(ctx, tx, ReceiptJob{
			TenantID:   sc.TenantID,      // the only copy the worker will ever get
			OrderID:    order.ID,         // ids and scalars, by value
			CustomerID: order.CustomerID,
			TotalCents: order.TotalCents,
		})
	})
	if err != nil {
		return nil, err
	}
	return order, nil
}
```

**Or start after commit, with the inputs snapshotted by value.** Used when the work
cannot be a row: a cache invalidation, a metric.

```go
// ✔ Commit first. The snapshot is taken before the goroutine exists.
func (s *Service) Create(
	ctx context.Context,
	sc domain.Scope,
	in CreateOrder,
) (*Order, error) {
	order, err := s.createCommitted(ctx, sc, in)
	if err != nil {
		return nil, err
	}
	// The tenant is in the key for the same reason the job carries one: the Worker
	// reads this off a channel, with no request behind it to ask.
	s.invalidations.Submit(CacheKey{ // a Worker's inbox
		TenantID:   sc.TenantID,
		CustomerID: order.CustomerID,
	})
	return order, nil
}
```

Never enqueue to a *different* system inside a transaction. A broker has no idea
your transaction exists and will not roll back when it aborts.

### By value means serializable, not just copied

```go
// ✘ The payload holds a pointer into the request's object graph.
type ReceiptJob struct{ Order *Order }
```

That cannot cross a process boundary, cannot be written to a queue, and cannot be
read back in three weeks by a consumer that was deployed after the enqueue. Even
in-process it is a bug: the caller still holds that `*Order` and something will
mutate it while the job reads it, which is a data race that `go test -race` only
catches if a test happens to do both.

```go
// ✔ The payload carries the scalars the job needs, or an id it re-reads after
// commit. Both survive being JSON in a table for a week.
type ReceiptJob struct {
	TenantID   int64 `json:"tenant_id"`
	OrderID    int64 `json:"order_id"`
	CustomerID int64 `json:"customer_id"`
	TotalCents int64 `json:"total_cents"`
}
```

### The tenant is in the payload because nothing else can put it there

A request carries its tenant implicitly, in the credential the middleware already
verified. **A job has no credential and no request.** The async boundary is where
tenancy dies quietly: the payload is the only thing that survives the enqueue, so a
tenant that is not written into it is gone - not wrong, gone, and there is nowhere to
go and look it up. The consumer then cannot call `s.store.Find(ctx, sc, id)` at all,
because that method demands a `domain.Scope` and there is nothing to build one from.

The worse outcome is the one that compiles: `domain.Scope{}`. `Scope{}.TenantID` is 0,
which matches no rows - until the backfill that inserts a row with a zero default, at
which point it matches all of them (`references/data-layer.md`).

### Always bounded

Every unit of work gets a deadline derived from the root context, so it honours
both shutdown and its own patience:

```go
func (s *Service) SendReceipt(ctx context.Context, m worker.Message) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	var j ReceiptJob
	if err := json.Unmarshal(m.Payload, &j); err != nil {
		// This payload will not parse on attempt 8 either. Terminal, immediately.
		return fmt.Errorf("%w: unmarshal receipt job: %v", ErrPermanent, err)
	}

	// The scope is rebuilt from the payload and checked before anything uses it. A
	// payload with no tenant will have no tenant on attempt 8 either, so it is
	// permanent, not retryable - eight sends against a zero scope is eight chances
	// to touch the wrong rows, spread over nine minutes so the logs never line up.
	sc := domain.Scope{TenantID: j.TenantID}
	if err := sc.Validate(); err != nil {
		return fmt.Errorf("%w: %v", ErrPermanent, err)
	}

	return s.mail.SendReceipt(ctx, sc, mailer.ReceiptRequest{
		OrderID:    j.OrderID,
		CustomerID: j.CustomerID,
		TotalCents: j.TotalCents,
	})
}
```

`context.WithTimeout(ctx, ...)` and not `context.WithTimeout(context.Background(),
...)`: the second one is a job that ignores shutdown, and shutdown will then wait
its full `Stop` timeout for it every single deploy.

## A job's identity is its inputs, never when it was scheduled

```go
// ✘
type ReceiptJob struct {
	OrderID     int64     `json:"order_id"`
	RequestedAt time.Time `json:"requested_at"`
}

func (j ReceiptJob) Key() string {
	b, _ := json.Marshal(j)
	return fmt.Sprintf("%x", sha256.Sum256(b))
}
```

Every retry, every redelivery, every double-clicked button produces a different
key for the same work. Dedupe still runs, still costs a round trip, and never
matches once. The customer gets two receipts and the unique index that was supposed
to stop it reports zero conflicts, so the metric says the system is working.

Worse, the payload is now load-bearing: you cannot add dedupe later without
changing its shape, and you cannot change its shape while jobs of the old shape are
still in the queue. The fix costs a drain.

```go
// ✔ Identity is what the job does. Same work, same key, forever.
type ReceiptJob struct {
	TenantID   int64 `json:"tenant_id"`
	OrderID    int64 `json:"order_id"`
	CustomerID int64 `json:"customer_id"`
	TotalCents int64 `json:"total_cents"`
}

// Version the key. When the job's MEANING changes, receipt:v2: lets the new job
// run for orders the v1 job already handled, without touching a single row.
//
// TenantID is an input and is deliberately not in the key: orders.id is an identity
// column, so it is unique across the whole table and already names one order. Put a
// tenant in the key only where the id it accompanies is unique per tenant rather
// than per table - then the id alone is two jobs wearing one name.
func (j ReceiptJob) Key() string {
	return fmt.Sprintf("receipt:v1:%d", j.OrderID)
}
```

Time is allowed in a key when time is the *work*. A daily digest's identity is the
period it covers, not the instant the ticker fired:

```go
// ✔ The day is data. The firing instant is not.
func (j DigestJob) Key() string {
	return fmt.Sprintf("digest:v1:%d:%s", j.UserID, j.Day.Format("2006-01-02"))
}
```

That key is what makes a retry at 00:03 and a manual backfill at 11:00 the same
job. `time.Now()` in the key makes them two, and the user gets two digests.

**Dedupe lives in the index, not in the application.** A check-then-insert in Go has
a window between the check and the insert, and with replicas someone is always
standing in it.

```sql
create table jobs (
    id          bigserial primary key,
    key         text        not null,
    payload     jsonb       not null,
    state       text        not null default 'pending',
    attempt     int         not null default 0,
    run_after   timestamptz not null default now(),
    claimed_at  timestamptz,
    last_error  text,
    created_at  timestamptz not null default now()
);

-- Two enqueues of the same work collide here and the second is a no-op. Partial,
-- so a job that has finished or been dead-lettered can legitimately be enqueued
-- again later.
create unique index jobs_key_active on jobs (key)
    where state in ('pending', 'running');

-- The claim path's index. Without it every Claim is a sequential scan over a table
-- whose churn is the whole point, and the queue gets slower exactly as it gets
-- busier - which is the moment you needed it fast.
create index jobs_claimable on jobs (run_after) where state = 'pending';
```

### That table is the queue

`PgQueue` is the only implementation of `Queue`, and it is nothing but the writes that
move a row between the states the schema just declared. There is no queue object with
a life of its own: the table holds the jobs, and this type is the only code allowed to
say so.

```go
// internal/worker/pgqueue.go

type PgQueue struct {
	db  *sql.DB
	log *slog.Logger
}

func NewPgQueue(db *sql.DB, log *slog.Logger) *PgQueue {
	return &PgQueue{db: db, log: log.With("queue", "jobs")}
}

// The tx is required, not optional. A job that can be enqueued without one can be
// enqueued before the row it describes exists, and that bug is a race you re-roll on
// every request. Demanding the tx here is how the compiler refuses to write it.
func (q *PgQueue) Enqueue(ctx context.Context, tx *sql.Tx, p Payload) error {
	b, err := json.Marshal(p)
	if err != nil {
		return fmt.Errorf("marshal %s: %w", p.Key(), err)
	}
	// do nothing, not an error: jobs_key_active is the dedupe, and the second enqueue
	// of the same work is a success. It means the work is queued, which is what the
	// caller asked for. Erroring here turns every double-clicked button into a 500.
	const stmt = `
		insert into jobs (key, payload)
		     values ($1, $2)
		on conflict do nothing`
	if _, err := tx.ExecContext(ctx, stmt, p.Key(), b); err != nil {
		return fmt.Errorf("enqueue %s: %w", p.Key(), err)
	}
	return nil
}

// Ack ends the job. The row is kept, out of the partial unique index, so the same key
// can legitimately be enqueued again tomorrow.
func (q *PgQueue) Ack(ctx context.Context, id int64) error {
	const stmt = `update jobs set state = 'done', claimed_at = null where id = $1`
	if _, err := q.db.ExecContext(ctx, stmt, id); err != nil {
		return fmt.Errorf("ack job %d: %w", id, err)
	}
	return nil
}

// Retry hands the row back with a time on it. The backoff is a value in run_after,
// which the claim's index already reads - not a sleeping goroutine holding a slot for
// four minutes to achieve the same delay at the cost of a worker.
func (q *PgQueue) Retry(ctx context.Context, id int64, runAfter time.Time) error {
	const stmt = `
		update jobs
		   set state = 'pending', run_after = $2, claimed_at = null
		 where id = $1`
	if _, err := q.db.ExecContext(ctx, stmt, id, runAfter); err != nil {
		return fmt.Errorf("retry job %d: %w", id, err)
	}
	return nil
}

// DeadLetter keeps the row, the payload and the cause. The person who opens this
// table at 3am has nothing else to go on, and "it failed" is not a finding.
func (q *PgQueue) DeadLetter(ctx context.Context, id int64, cause string) error {
	const stmt = `
		update jobs
		   set state = 'dead', last_error = $2, claimed_at = null
		 where id = $1`
	if _, err := q.db.ExecContext(ctx, stmt, id, cause); err != nil {
		return fmt.Errorf("dead-letter job %d: %w", id, err)
	}
	return nil
}
```

## Every retry needs a bound and a terminus

```go
// internal/worker/retry.go

// ErrPermanent marks work that cannot succeed on any attempt. Retrying a
// malformed payload eight times burns the queue's throughput on arithmetic that
// is already decided.
var ErrPermanent = errors.New("permanent")

// maxAttempts: ~2s to ~4m of backoff, about 9 minutes of trying. Past that the
// dependency is not flapping, it is broken, and no number of retries is going to
// substitute for a person.
const maxAttempts = 8

func backoff(attempt int, base, max time.Duration) time.Duration {
	if attempt > 20 {
		attempt = 20 // base<<21 overflows a Duration for any sane base, and a
		             // negative delay is an instant retry storm against a service
		             // that is already down
	}
	d := base * (1 << attempt)
	if d > max || d <= 0 {
		d = max
	}
	// Jitter over [d/2, d]. Without it, every job that failed in the same outage
	// retries in the same millisecond, and the retry is the second outage. This is
	// how a dependency that came back up goes down again.
	half := d / 2
	return half + time.Duration(rand.Int64N(int64(half)+1)) // math/rand/v2
}

func handleOne(ctx context.Context, q Queue, h Handler, m Message, log *slog.Logger) {
	log = log.With("job", m.Key, "attempt", m.Attempt)

	err := h(ctx, m)

	switch {
	case err == nil:
		// The ack is a separate write from the work. If it fails, the job
		// redelivers and runs twice. That makes at-least-once the contract and
		// idempotence the handler's obligation - not a caveat, the contract.
		if err := q.Ack(ctx, m.ID); err != nil {
			log.Error("ack failed, job will redeliver", "err", err)
		}

	case errors.Is(err, context.Canceled):
		// Shutdown took it mid-flight. Leave it claimed; the stale-claim reaper
		// below returns it to pending. Dead-lettering here would bury healthy work
		// every time you deploy.
		log.Info("job interrupted by shutdown, will be reclaimed")

	case errors.Is(err, ErrPermanent):
		deadLetter(ctx, q, m, err, log)

	case m.Attempt >= maxAttempts:
		deadLetter(ctx, q, m, err, log)

	default:
		next := time.Now().Add(backoff(m.Attempt, 2*time.Second, 4*time.Minute))
		if rerr := q.Retry(ctx, m.ID, next); rerr != nil {
			log.Error("reschedule failed, job stuck as running", "err", rerr)
			return
		}
		log.Warn("job failed, retrying", "at", next, "err", err)
	}
}

// deadLetter is where a job goes to be found by a person. The row is KEPT, with
// its payload and its last error, because the alternative is deleting work
// somebody promised a customer.
//
// Retry-forever with no terminus is not resilience, it is a slow leak: the job
// holds a queue slot for eternity, nothing ever alerts, and the data is lost
// exactly as thoroughly as if you had dropped it - just later, and with no record
// of when.
//
// A dead-letter table nobody watches is a table nobody reads. Page on depth > 0.
func deadLetter(ctx context.Context, q Queue, m Message, cause error, log *slog.Logger) {
	log.Error("job dead-lettered", "attempts", m.Attempt, "err", cause)
	if err := q.DeadLetter(ctx, m.ID, cause.Error()); err != nil {
		log.Error("dead-letter write failed, job stuck as running", "err", err)
	}
}
```

### The claim, and the reaper that makes it safe

```go
// Claim atomically takes a batch nobody else holds and marks the attempt. The
// attempt increments HERE, not on failure: a worker that is SIGKILLed mid-job
// would otherwise never record that it tried, and a poison job that crashes the
// process would be retried forever by a fresh replica every time.
func (q *PgQueue) Claim(ctx context.Context, n int) ([]Message, error) {
	const stmt = `
		update jobs
		   set state = 'running', attempt = attempt + 1, claimed_at = now()
		 where id in (
		       select id from jobs
		        where state = 'pending' and run_after <= now()
		        order by run_after
		        limit $1
		          for update skip locked
		 )
	 returning id, key, payload, attempt`

	rows, err := q.db.QueryContext(ctx, stmt, n)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Message
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ID, &m.Key, &m.Payload, &m.Attempt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
```

A worker that dies between `Claim` and `Ack` leaves `state = 'running'` forever. The
row is still there, still looking busy, so nothing alerts and nothing retries: the
job is lost invisibly, which is the worst way to lose one. The reaper is what closes
that hole, and it is - of course - a Worker:

```go
// ReclaimStale is a Job. Owned by the root like every other one.
//
// The interval must exceed the longest handler timeout, or this reaps jobs that
// are still legitimately running and you get every slow job executed twice.
func (q *PgQueue) ReclaimStale(ctx context.Context) error {
	const stmt = `
		update jobs
		   set state = 'pending', claimed_at = null
		 where state = 'running' and claimed_at < now() - $1::interval`
	res, err := q.db.ExecContext(ctx, stmt, "10 minutes")
	if err != nil {
		return fmt.Errorf("reclaim stale jobs: %w", err)
	}
	if n, _ := res.RowsAffected(); n > 0 {
		q.log.Warn("reclaimed stale jobs", "count", n) // warn: a worker died
	}
	return nil
}
```

Wired in the root exactly like the rest, which is the payoff for having one shape:

```go
reclaimer := worker.New("job-reclaimer", 2*time.Minute, log, jobs.ReclaimStale)
reclaimer.Start(ctx)
defer reclaimer.Stop(cfg.ShutdownTimeout)
```

## Once per cluster, when replicas exist

Two replicas run every ticker twice. The nightly rollup double-counts, the digest
sends twice, and the reconciler fights itself. Pick the primitive by **contention
shape**, not by which one you used last time.

| Contention shape | Primitive |
|---|---|
| One job, N replicas, one should run, not partitionable | advisory lock on the job name |
| Many independent items, N workers, each once | `select ... for update skip locked` |
| One contested row, N writers, all must apply | `select ... for update` on that row |

The wrong choice does not error. It degrades in a way that looks like something
else:

- **`for update` without `skip locked` on a work queue.** Every worker queues behind
  the same head row. N replicas deliver the throughput of one, and you scale by
  adding replicas that wait. The graph looks like a capacity problem, so someone
  adds capacity, and it does not move.
- **`skip locked` on a contested row.** The writers that skip it silently do
  nothing. The update is simply lost, no error, no log.
- **An advisory lock around a work queue.** Correct, and serial. Same shape as the
  first failure, arrived at deliberately.
- **A lock table with `owner` and `expires_at` instead of an advisory lock.** A
  holder that is SIGKILLed never clears its row, so the job stops running until
  someone notices the rollup has not fired in a week.

```go
// internal/lock/advisory.go
//
// pg_try_advisory_lock is session-scoped: it releases when the connection goes
// away, including when the process is killed. That property is the whole reason
// to use it over a lock table.
func (l *Lock) Run(
	ctx context.Context,
	key string,
	fn func(context.Context) error,
) error {
	// One connection for the whole critical section. Taking the lock on a pooled
	// connection and doing the work on whatever the pool hands you next is not a
	// lock at all: the pool can return the locking connection to the pool, another
	// caller can get it, and the unlock can run on a session that never held it.
	conn, err := l.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()

	id := int64(crc64.Checksum([]byte(key), crc64.MakeTable(crc64.ISO)))

	var got bool
	if err := conn.QueryRowContext(ctx,
		`select pg_try_advisory_lock($1)`, id).Scan(&got); err != nil {
		return fmt.Errorf("acquire %s: %w", key, err)
	}
	if !got {
		// try, not wait. Another replica has it and a second run of the same tick
		// is worth nothing. Waiting would queue all N replicas to run the job N
		// times back to back, which is the exact bug the lock was added to stop.
		return nil
	}

	defer func() {
		// A FRESH context. ctx is cancelled during shutdown, and unlocking on a
		// cancelled context fails, leaving the lock held until the connection is
		// reaped - so the job stops running cluster-wide until then.
		uctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := conn.ExecContext(uctx, `select pg_advisory_unlock($1)`, id); err != nil {
			l.log.Error("advisory unlock failed", "key", key, "err", err)
		}
	}()

	return fn(ctx)
}
```

Wrapping is a one-liner, because the lock is a Job decorator and the Worker never
learns about it:

```go
// The Worker does not know this job is cluster-unique. It does not need to: that
// is a property of the work, not of the loop.
rollup := worker.New("nightly-rollup", time.Hour, log, func(ctx context.Context) error {
	return lk.Run(ctx, "nightly-rollup", reportSvc.Rollup)
})
rollup.Start(ctx)
defer rollup.Stop(cfg.ShutdownTimeout)
```

A queue consumer needs none of this. `skip locked` already made every replica take
disjoint work, which is why the tiering matters: the durable-queue tier gets
cluster-safety for free, and the ticker tier has to buy it.

## Checklist

A background job is done when all of these are true. Any "no" is the bug you ship.

- It is a `Job` on the service that owns the logic, and a test calls it directly.
- It is wrapped in a Worker, constructed and stopped by the composition root.
- Its context descends from the root, so shutdown reaches it.
- It has a `context.WithTimeout` of its own.
- Its payload is serializable scalars. No pointers, no `time.Now()`.
- Its key is deterministic and versioned.
- It is idempotent, because at-least-once is the contract.
- Its retries have a backoff, a max, jitter, and a dead-letter someone alerts on.
- If it ticks and the service has replicas, it holds a lock chosen by contention
  shape.
- Its failures log at error, and its shutdown does not.
