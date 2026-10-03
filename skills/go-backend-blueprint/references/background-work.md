# Background work

Anything this service does that no request is waiting for: a side effect after a
response, a reconciler on a ticker, a job on a queue. There are three patterns, and
every piece of background work is exactly one of them.

The spine says background work is bounded, owned, and one of A, B or C. This is each
pattern, how to choose between them, and the rules all three share.

## Choose by what a loss costs

One question decides it: **what happens if this work never runs?**

| Answer | Pattern |
|---|---|
| Nothing anyone notices, or the next run fixes it; it must not block the response | **A**: fire-and-forget goroutine |
| Someone notices within the hour; one process keeps up; the work can be read from the database | **B**: embedded ticker in the HTTP service |
| Money, a legal duty, a promise to a customer or a third party; it must survive restarts, retry, and scale out | **C**: dedicated worker binary with a queue |

- **A** is for side effects whose loss is tolerable: a CRM sync after a write that the
  reconciler will repair anyway, a cache warm, a notification that is nice to have.
- **B** reads its work from the database it already has. No new infrastructure, no
  broker. A reconciler, an expiry sweep, a nightly rollup, a "release stranded
  reservations" pass. With replicas, it needs a lock.
- **C** is for work that must outlive the process that created it, and the process
  that created it is restarted on every deploy: moving deals through a pipeline on a
  schedule, capturing a payment, delivering a webhook someone is waiting for.

**Choose by what loss costs, not by what is interesting to build.** C for a cache
refresh buys a Redis to operate, a dead-letter list to watch and a new outage mode in
exchange for a guarantee nobody asked for. A for a payment buys a silent hole in the
ledger that reconciliation finds in a quarter, if you have reconciliation. Move up a
pattern when the answer changes, not before.

## What a bare `go` gets wrong

```go
// ✘ In a service method.
func (s *DealServiceImpl) MoveDeal(deal *model.Deal, stageID int) error {
	tx := database.Db.Begin()
	tx.Model(deal).Update("stage_id", stageID)
	go s.actionService.TriggerActionsForDeal(context.Background(), deal, stageID)
	return tx.Commit().Error
}
```

- **It starts before the commit.** The goroutine reads the deal on its own connection
  and may not see the new stage yet; or it wins the race and acts; or the commit fails
  and it acts on a move that never happened. Which one you get is re-rolled per call.
- **It captured a pointer.** `deal` is still owned by the caller, who may mutate it
  while the goroutine reads it. That is a data race `go test -race` catches only if a
  test happens to do both at once.
- **It has no deadline.** `context.Background()` with no timeout: a hung peer holds this
  goroutine and its connection forever. Ten thousand of those is the memory graph you
  get paged for, and the peer is fine by the time you look.
- **It has no recover.** A panic in any goroutine kills the whole process, including
  every unrelated request in flight. The stack names the action service, not the deal
  that triggered it.

The fix for A is not to ban `go`. It is one helper that makes all four impossible to
forget.

## Pattern A: fire-and-forget, through one helper

```go
// pkg/concurrency/concurrency.go
package concurrency

import (
	"context"
	"runtime/debug"
	"sync"
	"time"

	"example.com/users-service/pkg/logger"
)

// Go runs fn in a goroutine with a deadline and a panic guard, and logs its failure.
// It is the ONLY way this service starts a goroutine outside a worker. A bare `go` in
// a service method is a review comment.
//
// The context is deliberately detached from the request: the request's context is
// cancelled the instant the handler returns, which would cancel this work essentially
// always. The deadline is what bounds it instead.
//
// What this does NOT give you: shutdown does not wait for it. That is the definition
// of Pattern A, and it is why Pattern A is only for work whose loss is tolerable. If
// losing it on a deploy is not tolerable, it is Pattern B or C.
func Go(name string, timeout time.Duration, fn func(ctx context.Context) error) {
	go func() {
		defer func() {
			if r := recover(); r != nil {
				logger.Logger.WithField("stack", string(debug.Stack())).
					Errorf("background %s panicked: %v", name, r)
			}
		}()
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		if err := fn(ctx); err != nil {
			logger.Logger.Errorf("background %s failed: %v", name, err)
		}
	}()
}

// Run processes items with at most limit in flight, and returns when all are done. It
// is the bounded fan-out for inside a tick or a job: N concurrent calls to a peer is a
// number someone chose, not however many rows the query happened to return.
func Run[T any](limit int, items []T, job func(T)) {
	var wg sync.WaitGroup
	sem := make(chan struct{}, limit)
	for _, item := range items {
		wg.Add(1)
		sem <- struct{}{}
		go func(item T) {
			defer wg.Done()
			defer func() { <-sem }()
			defer func() {
				if r := recover(); r != nil {
					logger.Logger.WithField("stack", string(debug.Stack())).Errorf("concurrency.Run item panicked: %v", r)
				}
			}()
			job(item)
		}(item)
	}
	wg.Wait()
}
```

```go
// ✔ After the commit, snapshotted by value, bounded, guarded.
func (s *DealServiceImpl) MoveDeal(parentUserID, dealID, stageID int) error {
	var deal model.Deal
	err := helpers.SafeDBTransaction(database.Db, func(tx *gorm.DB) error {
		res := tx.Scopes(helpers.TenantScope(parentUserID)).
			Model(&model.Deal{}).Where("id = ?", dealID).Update("stage_id", stageID)
		if res.Error != nil {
			return res.Error
		}
		if res.RowsAffected == 0 {
			return contracts.ErrDealNotFound
		}
		return tx.Scopes(helpers.TenantScope(parentUserID)).First(&deal, dealID).Error
	})
	if err != nil {
		return fmt.Errorf("move deal %d: %w", dealID, err)
	}

	// The commit has happened: the goroutine cannot see a state that rolls back.
	// The snapshot is a VALUE, taken here, before the goroutine exists.
	snapshot := deal
	concurrency.Go("trigger stage actions", 10*time.Minute, func(ctx context.Context) error {
		return s.actionService.TriggerActionsForDeal(ctx, snapshot, stageID)
	})
	return nil
}
```

The rules for A:

- **Start after the commit**, never inside the transaction callback.
- **Capture values, not pointers.** Copy the struct, copy the ids.
- **Through `concurrency.Go`**, so the deadline and the recover are not optional.
- **Failures are logged, never returned to the response.** The response already went.
- **If a lost run must be repaired, something else repairs it**: a Pattern B
  reconciler that finds the rows A should have handled. Pattern A plus a reconciler is
  a legitimate design. Pattern A alone, for work that matters, is a hole.

## Pattern B: an embedded ticker, owned by `main`

```go
// pkg/worker/ticker.go
package worker

import (
	"context"
	"errors"
	"runtime/debug"
	"time"

	"example.com/users-service/pkg/logger"
)

// Job is the only thing a resource writes. It is a method on the service that owns the
// logic, so a test calls it directly with no ticker anywhere.
type Job func(ctx context.Context) error

// Ticker is every Pattern B worker in the service. One shape, so a reader who has read
// one has read them all, and there is exactly one place to add a metric.
type Ticker struct {
	name   string
	every  time.Duration
	job    Job
	cancel context.CancelFunc
	done   chan struct{}
}

func NewTicker(name string, every time.Duration, job Job) *Ticker {
	return &Ticker{name: name, every: every, job: job, done: make(chan struct{})}
}

// Start is non-blocking and is called once, by main, with the root context. Not from
// SetupRouter and not from a service: a goroutine whose owner is not main is a
// goroutine nothing stops.
func (t *Ticker) Start(ctx context.Context) {
	ctx, t.cancel = context.WithCancel(ctx)
	go func() {
		defer close(t.done)
		logger.Logger.Infof("worker %s started, every %s", t.name, t.every)
		defer logger.Logger.Infof("worker %s stopped", t.name)

		tick := time.NewTicker(t.every)
		defer tick.Stop()
		for {
			// Check cancellation before working, not only after. A select over a ready
			// ticker and a done context picks at random, so without this a stopped
			// worker runs one more tick about half the time, and writes rows after
			// shutdown on one deploy in six.
			if ctx.Err() != nil {
				return
			}
			t.runOnce(ctx)
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
			}
		}
	}()
}

// runOnce is the panic boundary and the per-tick deadline. A tick may not outlive its
// own interval: a wedged query that holds a tick open past the next one is how two
// ticks of a "single" worker end up running at once.
func (t *Ticker) runOnce(ctx context.Context) {
	defer func() {
		if r := recover(); r != nil {
			logger.Logger.WithField("stack", string(debug.Stack())).Errorf("worker %s panicked: %v", t.name, r)
		}
	}()
	tickCtx, cancel := context.WithTimeout(ctx, t.every)
	defer cancel()

	start := time.Now()
	switch err := t.job(tickCtx); {
	case err == nil:
		logger.Logger.Debugf("worker %s tick ok in %s", t.name, time.Since(start))
	case errors.Is(err, context.Canceled):
		// Shutdown, not a failure. Logging it at error teaches everyone to ignore this
		// worker's error logs, which is where the real one will be.
		logger.Logger.Infof("worker %s tick cancelled", t.name)
	default:
		logger.Logger.Errorf("worker %s tick failed after %s: %v", t.name, time.Since(start), err)
	}
}

// Stop asks, then waits, under a bound. Cancelling is the ask; the receive on done is
// the answer. A job that ignores its context would otherwise hold the process open
// until SIGKILL arrives mid-write, so it is abandoned here, loudly, naming the worker.
func (t *Ticker) Stop(timeout time.Duration) {
	if t.cancel == nil {
		return // never started; Stop must be safe on the boot-failure path
	}
	t.cancel()
	select {
	case <-t.done:
	case <-time.After(timeout):
		logger.Logger.Errorf("worker %s did not stop within %s, abandoning", t.name, timeout)
	}
}
```

The job is a plain service method:

```go
// internal/resources/credit_resource/credit.service.go

// ReleaseStrandedReservations is a worker.Job. It knows nothing about tickers;
// TestReleaseStrandedReservations calls it directly.
func (s *CreditServiceImpl) ReleaseStrandedReservations(ctx context.Context) error {
	// Bounded batch: a tick does a fixed amount of work, and a backlog is drained over
	// several ticks instead of one tick that runs for an hour.
	var stranded []model.CreditReservation
	err := helpers.SafeDBQuery(func() error {
		return database.Db.WithContext(ctx).
			Where("status = ? AND created_at < ?", contracts.ReservationPending, time.Now().Add(-time.Hour)).
			Order("id").Limit(500).Find(&stranded).Error
	})
	if err != nil {
		return fmt.Errorf("find stranded reservations: %w", err)
	}

	concurrency.Run(10, stranded, func(r model.CreditReservation) {
		// Idempotent: the conditional update releases a reservation once, however many
		// ticks or replicas see it.
		if err := s.release(ctx, r); err != nil {
			logger.Logger.Errorf("release reservation %d: %v", r.ID, err)
		}
	})
	return nil
}
```

And it is wired exactly like every other worker, which is the payoff for one shape:

```go
// internal/routes/routes.go, at the end of SetupRouter
return []BackgroundWorker{
	worker.NewTicker("release-stranded-credits", time.Hour,
		helpers.ClusterOnce(database.Db, "release-stranded-credits", creditService.ReleaseStrandedReservations)),
}
```

The rules for B:

- **Constructed in `SetupRouter`, returned to `main`, started with the root context,
  stopped in reverse order** (`references/composition-and-lifecycle.md`). Never
  started inside `SetupRouter`, never with `context.Background()`.
- **The job is a service method** with the signature `func(ctx context.Context) error`.
- **Every query in it uses `WithContext(ctx)`**, so shutdown and the tick deadline
  actually stop it instead of waiting for the query to finish on its own.
- **A tick does a bounded batch**, and fans out through `concurrency.Run` with a limit.
- **It is idempotent**, because a tick that died halfway is re-run from the start.
- **With replicas, it holds a cluster lock** (see "Once per cluster").

## Pattern C: a worker binary, a sweeper and a queue

For work that must survive restarts, be retried, and scale beyond one process.

```
cmd/main.go            the HTTP API (unchanged)
cmd/worker/main.go     no HTTP: config, database, queue, the graph it needs, the loop
pkg/queue/queue.go     Redis: a sorted set scored by run-at time, leased with Lua
```

Three parts, each with one job:

1. **The sweeper** reads the database and schedules jobs. It is a Pattern B ticker,
   in either binary, and it is the source of truth for what work exists.
2. **The queue** holds what is due and when. A Redis sorted set: member is the job's
   identity, score is when it may next run.
3. **The worker loop** leases due jobs, runs them with bounded concurrency, and acks or
   fails each one.

### The queue

```go
// pkg/queue/queue.go
package queue

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	ScheduledKey = "<service>:scheduled_jobs" // the sorted set
	AttemptsKey  = "<service>:job_attempts"   // hash: member -> attempts so far
	DeadKey      = "<service>:failed_jobs"    // list: what a person must look at
	LeaseFor     = 15 * time.Minute           // MUST exceed the longest job's timeout
	MaxAttempts  = 8
)

// Job is the job's IDENTITY and nothing else: the inputs that say what work this is.
// No timestamp, no attempt count, no request id. Two schedules of the same work must
// serialize to the same bytes, or NX cannot dedupe them (see "A job's identity").
type Job struct {
	Kind         string `json:"kind"` // a contracts constant, versioned: "deal_move:v1"
	ParentUserID int    `json:"parent_user_id"`
	CampaignID   int    `json:"campaign_id"`
	StageID      int    `json:"stage_id"`
}

type Queue struct{ rdb *redis.Client }

func New(rdb *redis.Client) *Queue { return &Queue{rdb: rdb} }

// Schedule adds the job if it is not already scheduled. NX: a second schedule of the
// same work is a no-op and a success, because the work is queued, which is what the
// caller asked for. Erroring would turn every sweeper overlap into an alert.
func (q *Queue) Schedule(ctx context.Context, job Job, runAt time.Time) error {
	member, err := json.Marshal(job)
	if err != nil {
		return fmt.Errorf("marshal job: %w", err)
	}
	return q.rdb.ZAddArgs(ctx, ScheduledKey, redis.ZAddArgs{
		NX:      true,
		Members: []redis.Z{{Score: float64(runAt.Unix()), Member: member}},
	}).Err()
}

// lease takes up to n due jobs and pushes each one's score LeaseFor into the future,
// atomically. A job leased by a worker that then dies becomes due again when the lease
// runs out - which is the stale-claim reaper, for free, with no second process.
var lease = redis.NewScript(`
local due = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', ARGV[1], 'LIMIT', 0, ARGV[2])
for _, member in ipairs(due) do
  redis.call('ZADD', KEYS[1], 'XX', ARGV[3], member)
end
return due`)

func (q *Queue) Lease(ctx context.Context, n int) ([]Job, error) {
	now := time.Now()
	raw, err := lease.Run(ctx, q.rdb, []string{ScheduledKey},
		now.Unix(), n, now.Add(LeaseFor).Unix()).StringSlice()
	if err != nil {
		return nil, fmt.Errorf("lease: %w", err)
	}
	jobs := make([]Job, 0, len(raw))
	for _, m := range raw {
		var j Job
		if err := json.Unmarshal([]byte(m), &j); err != nil {
			// A member that does not parse will not parse next time either. Dead-letter
			// it now rather than lease it every LeaseFor forever.
			q.deadLetter(ctx, m, fmt.Sprintf("unparseable: %v", err))
			continue
		}
		jobs = append(jobs, j)
	}
	return jobs, nil
}

// Ack ends the job. The ack is a separate write from the work: if it fails, the lease
// expires and the job runs again. At-least-once is the contract and idempotence is the
// handler's obligation - not a caveat, the contract.
func (q *Queue) Ack(ctx context.Context, job Job) error {
	member, _ := json.Marshal(job)
	pipe := q.rdb.TxPipeline()
	pipe.ZRem(ctx, ScheduledKey, member)
	pipe.HDel(ctx, AttemptsKey, string(member))
	_, err := pipe.Exec(ctx)
	return err
}

// Fail reschedules with backoff, or dead-letters at the terminus. The member is
// unchanged, so the job keeps its identity across retries and the sweeper's NX still
// dedupes against it.
func (q *Queue) Fail(ctx context.Context, job Job, cause error, permanent bool) error {
	member, _ := json.Marshal(job)
	attempts, err := q.rdb.HIncrBy(ctx, AttemptsKey, string(member), 1).Result()
	if err != nil {
		return fmt.Errorf("count attempt: %w", err)
	}
	if permanent || attempts >= MaxAttempts {
		return q.deadLetter(ctx, string(member), cause.Error())
	}
	next := time.Now().Add(backoff(int(attempts), 2*time.Second, 4*time.Minute))
	return q.rdb.ZAddArgs(ctx, ScheduledKey, redis.ZAddArgs{
		XX:      true,
		Members: []redis.Z{{Score: float64(next.Unix()), Member: member}},
	}).Err()
}

// deadLetter keeps the job and its last error where a person will find them. The
// alternative to a dead letter is retrying forever (a slot held for eternity, nothing
// alerting) or dropping it (work somebody promised a customer, deleted). Page on the
// list's length being above zero; a dead-letter list nobody watches is a list nobody
// reads.
func (q *Queue) deadLetter(ctx context.Context, member, cause string) error {
	entry, _ := json.Marshal(map[string]string{"job": member, "error": cause, "at": time.Now().UTC().Format(time.RFC3339)})
	pipe := q.rdb.TxPipeline()
	pipe.ZRem(ctx, ScheduledKey, member)
	pipe.HDel(ctx, AttemptsKey, member)
	pipe.LPush(ctx, DeadKey, entry)
	_, err := pipe.Exec(ctx)
	return err
}

// backoff is exponential with jitter over [d/2, d]. Without the jitter, every job that
// failed in the same outage retries in the same second, and the retry is the second
// outage: it is how a dependency that came back up goes down again.
func backoff(attempt int, base, max time.Duration) time.Duration {
	if attempt > 20 {
		attempt = 20 // base<<21 overflows; a negative delay is an instant retry storm
	}
	d := base * (1 << attempt)
	if d > max || d <= 0 {
		d = max
	}
	half := d / 2
	return half + time.Duration(rand.Int64N(int64(half)+1))
}
```

### The worker binary

```go
// cmd/worker/main.go
package main

import (
	"context"
	"errors"
	"os"
	"os/signal"
	"syscall"
	"time"

	"example.com/deals-service/database"
	"example.com/deals-service/internal/config"
	"example.com/deals-service/internal/contracts"
	dealresource "example.com/deals-service/internal/resources/deal_resource"
	"example.com/deals-service/pkg/concurrency"
	"example.com/deals-service/pkg/logger"
	"example.com/deals-service/pkg/queue"
	usersclient "example.com/deals-service/pkg/users_client"

	"github.com/redis/go-redis/v9"
)

func main() {
	config.LoadConfig()
	database.LoadDatabase()
	rdb := redis.NewClient(&redis.Options{Addr: config.GlobalConfig.RedisAddr})
	q := queue.New(rdb)

	// The slice of the graph this binary needs. Same constructors, same order, same
	// panic-on-error as SetupRouter: a worker is not a second way to build a service.
	usersClient := usersclient.NewUsersClient(config.GlobalConfig.UsersServiceBaseURL,
		config.GlobalConfig.InternalServicesWebhookSecret)
	dealService, err := dealresource.NewDealService(usersClient)
	if err != nil {
		panic("Failed to initialise deal service: " + err.Error())
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	poll := time.NewTicker(5 * time.Second)
	defer poll.Stop()

	for ctx.Err() == nil {
		select {
		case <-ctx.Done():
		case <-poll.C:
			jobs, err := q.Lease(ctx, 100)
			if err != nil {
				logger.Logger.Errorf("lease: %v", err)
				continue
			}
			// Bounded: 20 in flight, and the poll does not proceed until the batch is
			// done, so a slow batch slows the queue instead of piling up goroutines.
			concurrency.Run(20, jobs, func(job queue.Job) {
				// A per-job deadline under the lease, derived from the root context so a
				// SIGTERM stops the job, not just the loop.
				jobCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
				defer cancel()
				err := dealService.ProcessMoveJob(jobCtx, job)
				switch {
				case err == nil:
					if err := q.Ack(ctx, job); err != nil {
						logger.Logger.Errorf("ack %v: %v (will re-run after the lease)", job, err)
					}
				case errors.Is(err, context.Canceled):
					// Shutdown took it mid-flight. Leave it leased; it becomes due again
					// when the lease expires. Failing it would burn an attempt per deploy.
				default:
					permanent := errors.Is(err, contracts.ErrNonRetryable)
					if ferr := q.Fail(ctx, job, err, permanent); ferr != nil {
						logger.Logger.Errorf("fail %v: %v", job, ferr)
					}
				}
			})
		}
	}

	// The batch in flight finished inside concurrency.Run before the loop re-checked
	// ctx, so nothing is mid-job here. Close what this binary opened, last.
	_ = rdb.Close()
	database.CloseDatabase()
}
```

```go
// ✘ What the loop looks like without the root context wired to the signal.
ctx, cancel := context.WithCancel(context.Background())
sigChan := make(chan os.Signal, 1)
signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
// ...and nothing ever reads sigChan or calls cancel.
```

`signal.Notify` stops the default SIGTERM behaviour (exiting) and delivers the signal
to a channel instead. If nothing reads that channel, the process now **ignores**
SIGTERM: it runs until the orchestrator's grace period expires and SIGKILL lands,
mid-job, with the ack unwritten. `signal.NotifyContext` is the one call that both
captures the signal and cancels the context.

### Never schedule to Redis inside a database transaction

Redis does not know your transaction exists and will not roll back when it aborts. A
`Schedule` inside `SafeDBTransaction` enqueues work for a row that may never commit;
the worker then fails it as "not found", or acts on it if it races the rollback.

Schedule **after** the commit. And because a crash between the commit and the
`Schedule` loses the enqueue, **the sweeper is not optional in Pattern C**: it reads the
database for work that is due, schedules it with NX, and so re-creates any enqueue that
was lost. The database row is the record that work exists; the queue is a schedule
derived from it. That is what makes a two-system design safe without a distributed
transaction, and it only works if the job's identity is deterministic.

## A job's identity is its inputs, never when it was scheduled

```go
// ✘
type Job struct {
	DealID      int       `json:"deal_id"`
	RetryCount  int       `json:"retry_count"`
	ScheduledAt time.Time `json:"scheduled_at"`
}
```

Every retry, every sweep, every double-click produces different bytes for the same
work. NX still runs and never matches. The deal moves twice, the customer gets two
emails, and the dedupe that was supposed to stop it reports zero conflicts, so the
metric says the system is working. Worse, the payload is now load-bearing: you cannot
fix the identity without changing its shape, and you cannot change its shape while
jobs of the old shape are still in the set.

- **Identity is what the job does.** The ids it acts on and a versioned kind
  (`"deal_move:v1"`). When the job's meaning changes, `v2` lets the new job run for work
  the `v1` job already handled.
- **Attempt counts and timestamps live beside the identity**, never in it: the score is
  the run-at time, the attempts hash holds the count.
- **Time is allowed in the identity when time is the work.** A daily digest's identity
  is the day it covers (`"digest:v1"`, user, `2026-10-03`), not the instant the ticker
  fired. That is what makes a retry at 00:03 and a manual backfill at 11:00 the same
  job.
- **The tenant is in the payload**, because a job has no request and no credential, and
  the payload is the only thing that survives the enqueue. A job that cannot rebuild its
  `TenantScope` from its own fields cannot query safely, and a zero tenant is refused by
  the scope, which makes the job permanent-fail rather than touch the wrong rows.

## Every retry needs a bound and a terminus

- **Bounded:** `MaxAttempts`, then the dead letter. Retry-forever with no terminus is a
  slow leak: the job holds a slot for eternity, nothing alerts, and the work is lost as
  thoroughly as if it had been dropped, just later and with no record of when.
- **Backed off, with jitter.** See `backoff` above.
- **Permanent failures skip the retries.** A payload that does not parse, a tenant that
  no longer exists, a peer's 4xx that says the request itself is wrong: these will fail
  on attempt 8 exactly as they failed on attempt 1. The job returns an error wrapping
  `contracts.ErrNonRetryable`, and the loop dead-letters it immediately.
- **The in-process retry loop is not a second mechanism.** A client may retry an
  idempotent call a couple of times within one request (`references/inter-service.md`).
  Anything that needs minutes of retrying is a job on the queue, because a request
  goroutine cannot wait nine minutes: its client is gone and its `WriteTimeout` fired.

## Once per cluster, when replicas exist

Two replicas run every Pattern B ticker twice. The rollup double-counts, the digest
sends twice, the reconciler fights itself. The primitive for "one job, N replicas, one
should run" is a Postgres advisory lock, and it wraps the job, so the ticker never
knows:

```go
// internal/helpers/advisory_lock.helper.go
package helpers

import (
	"context"
	"fmt"
	"hash/crc64"

	"example.com/users-service/pkg/logger"

	"gorm.io/gorm"
)

// ClusterOnce wraps a job so that, across every replica, at most one runs it at a
// time. It takes the handle as a parameter (routes passes database.Db) because this
// package cannot import database: config imports helpers, and database imports config.
//
// pg_try_advisory_lock is session-scoped: it releases when the connection goes away,
// including when the process is SIGKILLed. That is the whole reason to use it over a
// lock table with an expires_at, which a killed holder never clears.
func ClusterOnce(db *gorm.DB, name string, job func(context.Context) error) func(context.Context) error {
	lockID := int64(crc64.Checksum([]byte(name), crc64.MakeTable(crc64.ISO)))

	return func(ctx context.Context) error {
		// One dedicated connection holds the lock for the whole run. Taking the lock on
		// a pooled connection and unlocking on whatever the pool hands back next is not
		// a lock: the unlock runs on a session that never held it. The job itself uses
		// the pool as normal, so this costs one extra connection while a locked job
		// runs - count it in DBMaxConns.
		return db.WithContext(ctx).Connection(func(conn *gorm.DB) error {
			var got bool
			if err := conn.Raw("SELECT pg_try_advisory_lock(?)", lockID).Scan(&got).Error; err != nil {
				return fmt.Errorf("acquire %s lock: %w", name, err)
			}
			if !got {
				// Try, not wait. Another replica is running it, and a second run of the
				// same tick is worth nothing. Waiting would queue every replica to run the
				// job back to back, which is the bug the lock exists to stop.
				return nil
			}
			defer func() {
				// A FRESH context: ctx is cancelled during shutdown, and an unlock on a
				// cancelled context fails, leaving the lock held until the connection is
				// reaped, so the job stops running cluster-wide until then.
				if err := conn.WithContext(context.Background()).
					Exec("SELECT pg_advisory_unlock(?)", lockID).Error; err != nil {
					logger.Logger.Errorf("release %s lock: %v", name, err)
				}
			}()
			return job(ctx)
		})
	}
}
```

The other two contention shapes (`FOR UPDATE`, `FOR UPDATE SKIP LOCKED`) are in
`references/data-layer.md`. Pattern C needs none of this: the Lua lease already gives
every worker disjoint jobs, which is why the patterns matter. C gets cluster-safety from
its queue; B has to buy it.

## Checklist

A piece of background work is done when all of these are true. Any "no" is the bug you
ship.

- It is exactly one of A, B or C, chosen by what losing a run costs.
- **A:** it starts after the commit, through `concurrency.Go`, with values, not
  pointers, and something repairs a lost run if a lost run matters.
- **B:** it is a `worker.Ticker` over a service method, constructed in `SetupRouter`,
  started and stopped by `main`, every query `WithContext(ctx)`, a bounded batch per
  tick, and `ClusterOnce` if there are replicas.
- **C:** the job's identity is deterministic and versioned, the sweeper re-derives work
  from the database, nothing schedules inside a transaction, retries are bounded with
  jitter and end in a dead letter someone alerts on, and the worker binary's context is
  wired to the signal.
- It is idempotent, because every pattern can run it twice.
- It carries its tenant, and rebuilds its scope from its own fields.
- Its failures log at error; its shutdown logs at info.
