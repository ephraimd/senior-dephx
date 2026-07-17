# Composition and lifecycle

How this service starts, what owns what while it runs, and how it stops without
leaving damage. One file, one function, one exit path.

The spine says `main` is the composition root and teardown is ordered. This is the
shape that makes both true.

## `main` is two lines; `run` is the graph

`main` turns a failure into an exit code. That is all it may do, because `os.Exit`
skips every pending defer - so a `main` that does the wiring is a `main` whose
cleanup never runs on the error path, and the one time you need the database
flushed is the one time the process died.

```go
// cmd/api/main.go
package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"example.internal/svc/internal/config"
	"example.internal/svc/internal/mailer"
	"example.internal/svc/internal/order"
	"example.internal/svc/internal/user"
	"example.internal/svc/internal/worker"
)

func main() {
	if err := run(); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

// run is the composition root. Every dependency this process has is constructed
// here, in dependency order, and passed down. If it is not in this function, this
// process does not have it.
func run() error {
	cfg := config.Load() // panics on required-and-missing, naming the key

	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel})
	log := slog.New(h).With("service", "orders", "env", cfg.Env)

	// The root context. It is cancelled on SIGINT/SIGTERM, and everything
	// constructed below inherits it, which is how a signal reaches a worker that
	// is three layers deep without anyone passing a channel around.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// --- Construct leaves first. Each defer is parked against its constructor,
	// --- which is what makes teardown reverse construction order for free: defers
	// --- are LIFO, so the only way to get the order wrong is to move a defer away
	// --- from the line that created the thing it closes.

	db, err := openDB(ctx, cfg, log)
	if err != nil {
		return fmt.Errorf("open db: %w", err)
	}
	defer db.Close()

	mail := mailer.NewClient(cfg.MailerURL, cfg.MailerToken, 10*time.Second)
	defer mail.Close() // owns an http.Transport; see "Ownership" below

	// Stores borrow the handle. Services own stores and clients.
	users := user.NewStore(db)
	orders := order.NewStore(db)

	userSvc := user.NewService(users, log)
	orderSvc := order.NewService(db, orders, users, mail, log)

	// Workers are owned by run, never by a service and never by a handler.
	// See references/background-work.md for the Worker shape; run only needs to
	// know it has Start(ctx) and Stop(timeout).
	reaper := worker.New("order-reaper", cfg.ReaperInterval, log, orderSvc.ExpireStale)
	reaper.Start(ctx)
	defer reaper.Stop(cfg.ShutdownTimeout)

	receipts := worker.NewConsumer("receipts", order.NewQueue(db), orderSvc.SendReceipt, log)
	receipts.Start(ctx)
	defer receipts.Stop(cfg.ShutdownTimeout)

	// Transport last: it is the only thing that lets work in, so it is the first
	// thing that must stop letting work in.
	ready := &atomic.Bool{}
	ready.Store(true)

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           router(cfg, log, ready, userSvc, orderSvc),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	return serve(ctx, srv, ready, cfg, log)
}
```

Read that function top to bottom and you know the entire process: what it talks to,
what runs in the background, what closes when. That property is the deliverable.
Wiring you have to grep for is an application nobody can hold in their head, and
nobody who cannot hold it will dare change it.

Timeouts on the `http.Server` are not decoration. A server with no
`ReadHeaderTimeout` holds a goroutine and a socket per opened-and-silent
connection, which is a denial of service anyone with a shell script can run
against you.

## Config: read once, at boot, into a typed struct

```go
// internal/config/config.go
package config

import (
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Env             string
	Addr            string
	LogLevel        slog.Level
	DatabaseURL     string
	MaxDBConns      int
	MailerURL       string
	MailerToken     string
	ReaperInterval  time.Duration
	ShutdownTimeout time.Duration
	ReadinessDelay  time.Duration
}

// Load is called exactly once, from the composition root, before anything else
// exists. After it returns, the process's inputs are fixed and typed, and the
// only way to reach one is to have been handed it.
func Load() Config {
	return Config{
		Env:             envOr("ENV", "development"),
		Addr:            envOr("ADDR", ":8080"),
		LogLevel:        levelOr("LOG_LEVEL", slog.LevelInfo),
		DatabaseURL:     mustEnv("DATABASE_URL"),
		MaxDBConns:      intOr("MAX_DB_CONNS", 20),
		MailerURL:       mustEnv("MAILER_URL"),
		MailerToken:     mustEnv("MAILER_TOKEN"),
		ReaperInterval:  durOr("REAPER_INTERVAL", time.Minute),
		ShutdownTimeout: durOr("SHUTDOWN_TIMEOUT", 20*time.Second),
		ReadinessDelay:  durOr("READINESS_DELAY", 5*time.Second),
	}
}

// mustEnv names the key it wanted. "config: required env var DATABASE_URL is not
// set" ends the incident at the first log line. A bare "invalid configuration"
// starts a bisect.
func mustEnv(key string) string {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		panic(fmt.Sprintf("config: required env var %s is not set", key))
	}
	return v
}

func envOr(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

// Absent means default. Present-and-garbage means panic - never the default.
// Falling back on a typo means the deploy silently ignores the value someone
// typed, runs on a number nobody chose, and reports success.
func intOr(key string, def int) int {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		panic(fmt.Sprintf("config: %s=%q is not an integer", key, v))
	}
	return n
}

func durOr(key string, def time.Duration) time.Duration {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		panic(fmt.Sprintf("config: %s=%q is not a duration (want 30s, 5m)", key, v))
	}
	return d
}

func levelOr(key string, def slog.Level) slog.Level {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def
	}
	var l slog.Level
	if err := l.UnmarshalText([]byte(v)); err != nil {
		panic(fmt.Sprintf("config: %s=%q is not a level (want debug|info|warn|error)", key, v))
	}
	return l
}
```

Rules this encodes:

- **Panic at boot, not at request time.** A required key that is missing kills the
  process before it accepts a single connection. The deploy fails, the previous
  version keeps serving, and the log line names the key. The alternative is a
  process that reports healthy and fails on the first request that reaches the
  unconfigured path, which may be the payment path, at 3am, on a Saturday.
- **Panic is correct here and nowhere else.** `Load` runs once, on the main
  goroutine, before any state exists to corrupt. That is the only place in this
  service where panicking is the honest move.
- **Every field is typed at the boundary.** `cfg.ReaperInterval` is a
  `time.Duration`. Nobody downstream parses anything, so nobody downstream parses
  it differently.
- **No `os.Getenv` in a call path. Ever.** A hidden input is invisible from the
  composition root, unreachable from a test, and it turns a boot error into
  somebody's afternoon:

```go
// ✘ The read is buried where nobody looks.
func (s *OrderService) Charge(ctx context.Context, o Order) error {
	key := os.Getenv("PAYMENT_KEY") // empty in CI, empty in the new region, empty
	                                // in every test that did not know to set it
	...
}

// ✔ The dependency is named, so the root supplies it and a test replaces it.
type OrderService struct{ paymentKey string }
```

## Banned: containers, `init()`, package singletons, global handles

```go
// ✘ The whole anti-pattern in six lines.
package store

var DB *sql.DB

func init() {
	DB, _ = sql.Open("pgx", os.Getenv("DATABASE_URL"))
}

func FindUser(ctx context.Context, id int64) (*User, error) {
	return scanUser(DB.QueryRowContext(ctx, `select id, email from users where id = $1`, id))
}
```

Count what that costs:

- The error is discarded, so a bad URL produces a nil `DB` and the failure is a
  nil-pointer panic on the first request instead of a refused boot.
- `init()` runs on import. `go test ./internal/store` now needs a live database to
  run a test that touches no database, so the suite is slow, flaky, and eventually
  skipped.
- Nothing can replace `DB`, because nothing was ever asked for it. The seam does
  not exist, so the test either talks to a real database or does not exist either.
- Nothing closes it. It lives until the process dies, however the process dies.
- The order of `init()` across packages is decided by the import graph, which means
  a new import in an unrelated file can reorder your startup.

```go
// ✔ The dependency has a name, so the root supplies it and a test replaces it.
package user

type Store struct{ db *sql.DB }

func NewStore(db *sql.DB) *Store { return &Store{db: db} }

func (s *Store) Find(ctx context.Context, id int64) (*User, error) {
	const q = `select id, email from users where id = $1`
	return scanUser(s.db.QueryRowContext(ctx, q, id))
}
```

**State a constructor does not name is state a test cannot replace and a reader
cannot find.** That is the entire rule. A DI container fails it the same way a
global does: the graph moves from a function you can read into a registry you have
to execute to understand, and "which implementation is live in production" becomes
a question you answer by running the program.

## Ownership: one owner, named at construction

**Every constructed resource has exactly one owner responsible for closing it.**
The owner is whoever constructed it. Handing a resource to a constructor does not
transfer ownership unless that constructor's doc comment says it does.

```go
// The store BORROWS the handle. It never closes it. If it did, the second store
// sharing that handle would start returning "sql: database is closed" from an
// unrelated endpoint, and the stack trace would name the innocent caller.
type Store struct{ db *sql.DB }
```

```go
// internal/mailer/client.go
//
// Client OWNS the transport it built, so it exposes Close and the root defers it.
// A resource with a constructor and no Close is a claim that it holds nothing -
// make that claim true or provide the Close.
type Client struct {
	http *http.Client
	tr   *http.Transport
	base string
	tok  string
}

func NewClient(base, token string, timeout time.Duration) *Client {
	tr := &http.Transport{
		MaxIdleConns:        64,
		MaxIdleConnsPerHost: 32,
		IdleConnTimeout:     90 * time.Second,
	}
	return &Client{
		tr:   tr,
		http: &http.Client{Transport: tr, Timeout: timeout},
		base: base,
		tok:  token,
	}
}

func (c *Client) Close() { c.tr.CloseIdleConnections() }
```

A constructor that fails owns the cleanup of whatever it built before it failed,
because the caller never received a handle and cannot close what it was never
given:

```go
func openDB(ctx context.Context, cfg config.Config, log *slog.Logger) (*sql.DB, error) {
	db, err := sql.Open("pgx", cfg.DatabaseURL)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(cfg.MaxDBConns)
	db.SetMaxIdleConns(cfg.MaxDBConns)
	db.SetConnMaxLifetime(30 * time.Minute)
	db.SetConnMaxIdleTime(5 * time.Minute)

	// sql.Open is lazy. It has not dialled anything and it will not fail on a
	// wrong password. Without this ping the process boots green, passes its
	// startup probe, and fails on the first request - which moves a config error
	// from the deploy that caused it to a user who did not.
	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := db.PingContext(pingCtx); err != nil {
		db.Close() // we opened it and the caller never saw it, so we close it
		return nil, fmt.Errorf("ping: %w", err)
	}

	log.Info("db connected", "max_conns", cfg.MaxDBConns)
	return db, nil
}
```

**The failure this prevents: a worker or a pool that outlives the process it
belonged to.** When a service constructs its own pool instead of being handed one,
nobody in `run` knows it exists, so nobody closes it. Its goroutines keep running
after `run` returns, its connections stay checked out on the server until an idle
reaper eventually kills them, and you are now holding two pools' worth of
connections against a limit you tuned for one. The symptom is "too many
connections" on a service you did not deploy, and the cause is a constructor that
took ownership without saying so.

## Shutdown: stop accepting, drain, close in reverse

Two distinct steps that get conflated. **Cancelling the context asks; `Stop` waits
for the answer.** A shutdown that only cancels is not a shutdown, it is a race you
usually win.

```go
func serve(
	ctx context.Context,
	srv *http.Server,
	ready *atomic.Bool,
	cfg config.Config,
	log *slog.Logger,
) error {
	// Buffered by one. On the shutdown path nobody reads this channel, and an
	// unbuffered send would block the listener goroutine forever.
	errCh := make(chan error, 1)

	go func() {
		log.Info("http listening", "addr", srv.Addr)
		err := srv.ListenAndServe()
		if errors.Is(err, http.ErrServerClosed) {
			err = nil // our own Shutdown, not a failure
		}
		errCh <- err
	}()

	select {
	case err := <-errCh:
		// Died on its own: port in use, permission denied. Never reached on the
		// normal path, and it must not be swallowed - a process that logs
		// "shutting down" when the port was busy hides the actual error.
		return fmt.Errorf("listen: %w", err)
	case <-ctx.Done():
		log.Info("shutdown signal received")
	}

	// 1. Stop being routed to, BEFORE closing the listener. Shutdown closes it
	// instantly, but the load balancer keeps sending for up to one health-check
	// interval, and every request it sends into a closed listener is a
	// connection-refused that the client sees as a 502. Those 502s are caused by
	// the deploy and blamed on the code.
	ready.Store(false)
	log.Info("readiness off, waiting for routing to drain", "delay", cfg.ReadinessDelay)
	time.Sleep(cfg.ReadinessDelay)

	// 2. Stop accepting and drain what is in flight, under a bound.
	//
	// The deadline gets its OWN context. ctx is already cancelled - that is why we
	// are here - so passing it to Shutdown makes Shutdown return immediately and
	// cut every in-flight request, which is precisely the thing this function
	// exists to prevent.
	drainCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()

	if err := srv.Shutdown(drainCtx); err != nil {
		// Requests still running at the deadline get cut mid-flight. Loud, not
		// silent: this is the line that tells you the grace period is too short
		// or an endpoint is too slow.
		return fmt.Errorf("drain exceeded %s: %w", cfg.ShutdownTimeout, err)
	}

	log.Info("http drained")
	return nil // run's defers now fire in reverse construction order
}
```

Then `run`'s defers unwind, and because each one was written against its
constructor, the order is exactly the reverse of the way the graph was built:

```
serve returns          -> no request is still running
receipts.Stop(...)     -> the queue consumer finishes its current message
reaper.Stop(...)       -> the ticker finishes its current tick
mail.Close()           -> idle connections released; nothing is using them now
db.Close()             -> LAST, because everything above needed it until now
stop()                 -> signal handler unregistered
```

Get that order wrong and the failure is specific. Close `db` before draining and
every in-flight request that was mid-query returns `sql: database is closed` as a
500 - to a user whose request was fine, on a deploy you called successful.

`ready` also decides what `/readyz` returns; `/healthz` is a separate endpoint that
checks nothing but the process. Liveness that pings the database restarts every
replica during a database blip, turning a thirty-second dependency wobble into a
full outage you caused.

### The bounded wait is not optional

Every `Stop` takes a deadline and logs when it blows it:

```go
// A job that ignores its context would otherwise hold the process open until the
// orchestrator's SIGKILL, which arrives with the tick mid-write. Abandon it here,
// loudly, so the log names the worker instead of leaving you a silent 137.
func (w *Worker) Stop(timeout time.Duration) {
	if w.cancel == nil {
		return
	}
	w.cancel()
	select {
	case <-w.done:
	case <-time.After(timeout):
		w.log.Error("worker did not stop in time, abandoning", "timeout", timeout)
	}
}
```

Budget the total. The orchestrator kills at its own grace period, so the sum of
every `Stop` timeout plus `ShutdownTimeout` plus `ReadinessDelay` must fit inside
it. If it does not, your careful ordering is decoration: SIGKILL arrives partway
down the list and the resources after it never close at all.

## What an unordered exit actually costs

`os.Exit(0)` on a signal, or no signal handling at all, is not "a faster restart".
It is this:

- A handler wrote its side effect and had not yet written its response. The socket
  dies. The client sees a network error, retries, and the effect happens twice.
  Nothing logged that. It surfaces days later as a duplicate charge, and by then
  nothing points back at the deploy that caused it.
- A worker had claimed a job and had not yet acked it. On restart it redelivers, so
  the job runs twice - which is survivable only because you made the handler
  idempotent, and you only did that if someone told you this would happen.
- A batch was halfway through writing rows outside a transaction. Half exist. No
  record says which half.

None of these produce an error log. That is the point: an unordered exit does not
fail, it truncates, and truncated work is damage with no signal attached. Someone
finds it later, without a stack trace, without a timestamp, without you.

## Refactor order

Bringing an existing service to this shape, one landable commit at a time. Nothing
below changes behaviour, which is what makes each step revertible on its own.

1. **Add `Config` and `Load`.** Wire it in `main` and pass it nowhere yet. Green.
2. **Kill `os.Getenv` call sites, leaf-first.** Each one becomes a field on the
   struct that needed it, supplied by the constructor. One package per commit.
3. **Give every global a constructor.** `var DB` becomes `NewStore(db)`. The global
   stays, temporarily assigned in `run`, so callers migrate one at a time.
4. **Delete the globals and the `init()`s.** This is the commit that cannot land
   until step 3 is finished everywhere, and it is the one that proves it is.
5. **Introduce `run`.** Move the wiring out of `main`, add the defers against their
   constructors.
6. **Add signal handling and `serve`.** Shutdown last, because it is worthless
   until the resources it orders actually have owners.

Do not reorder these. Adding graceful shutdown to a service that still has a global
`db` closes a handle that other packages are still holding, which converts a clean
exit into a crash and gets the whole effort reverted.
