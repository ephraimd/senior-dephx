# Composition and lifecycle

How this service starts, what it is made of while it runs, and how it stops without
leaving damage. Three files carry it: `cmd/main.go` owns the process, `internal/routes/
routes.go` owns the object graph, `internal/config/config.go` owns the inputs.

The spine says config is read once, composition happens in one function, and `main`
owns shutdown. This is the shape that makes all three true.

## `main` owns the process, and only `main`

`main` decides when the process starts accepting work, and it is the only code that
decides when it stops. Nothing else in the service may register a signal handler, call
`os.Exit`, or start something that outlives a request without handing it back to
`main` to stop.

```go
// cmd/main.go
package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"example.com/users-service/database"
	"example.com/users-service/internal/config"
	"example.com/users-service/internal/contracts"
	"example.com/users-service/internal/helpers"
	"example.com/users-service/internal/middleware"
	"example.com/users-service/internal/routes"
	"example.com/users-service/pkg/logger"

	"github.com/gin-gonic/gin"
)

// @title       Users Service
// @version     1.0
// @BasePath    /v1
func main() {
	// Inputs first. LoadConfig panics on a required-and-missing key, naming it, before
	// a single connection is open - so the deploy fails and the previous version keeps
	// serving. See "Config" below for why this is a call and not an init().
	config.LoadConfig()
	logger.SetLevel(config.GlobalConfig.LogLevel)

	if config.GlobalConfig.Env != string(contracts.LOCAL) {
		gin.SetMode(gin.ReleaseMode)
	}

	router := gin.New()
	// Order is load-bearing; references/http-layer.md says why each sits where it does.
	router.Use(
		middleware.Recovery(),
		middleware.AccessLog(),
		middleware.CORS(),
		middleware.SecureHeaders(),
	)
	helpers.RegisterJSONFieldNames()

	// The database is the one dependency every request needs. LoadDatabase panics if
	// it cannot connect, which is correct here: nothing is listening yet, nothing has
	// been accepted, and a refused boot is the cheapest place a bad DSN can fail.
	database.LoadDatabase()

	// The whole object graph, built in one function. It returns the background workers
	// it constructed and did not start, because starting and stopping them is a
	// lifecycle decision and lifecycle is this file's job.
	workers := routes.SetupRouter(router)

	// The root context. Cancelled on SIGINT/SIGTERM, and every worker derives from it,
	// which is how a signal reaches a ticker three layers down without anybody passing
	// a channel around.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	for _, w := range workers {
		w.Start(ctx)
	}

	server := &http.Server{
		Addr:    ":" + config.GlobalConfig.Port,
		Handler: router,
		// A server with no ReadHeaderTimeout holds a goroutine and a socket for every
		// connection that opens and then says nothing, which is a denial of service
		// anyone with a shell loop can run.
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      config.GlobalConfig.WriteTimeout,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}

	exitCode := serve(ctx, server)

	// Teardown, in reverse construction order. Every step below runs on BOTH paths -
	// the signal and the listener dying on its own - which is why none of them is a
	// defer that os.Exit would skip.
	for i := len(workers) - 1; i >= 0; i-- {
		workers[i].Stop(config.GlobalConfig.WorkerStopTimeout)
	}
	// LAST, because everything above needed it until this line: a request that was
	// mid-query when the database closed returns "sql: database is closed" as a 500,
	// to a user whose request was fine, on a deploy you called successful.
	database.CloseDatabase()

	logger.Logger.Info("shutdown complete")
	os.Exit(exitCode)
}

// serve runs the listener until the root context is cancelled or the listener dies,
// then drains in-flight requests under a bound. It returns the process exit code.
func serve(ctx context.Context, server *http.Server) int {
	// Buffered by one. On the shutdown path nobody reads this channel, and an
	// unbuffered send would block the listener goroutine forever.
	errCh := make(chan error, 1)
	go func() {
		logger.Logger.Infof("listening on %s", server.Addr)
		errCh <- server.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		// Died on its own: port in use, permission denied. Never swallowed - a process
		// that logs "shutting down" when the port was busy hides the actual error.
		if errors.Is(err, http.ErrServerClosed) {
			return 0
		}
		logger.Logger.Errorf("listener failed: %v", err)
		return 1
	case <-ctx.Done():
		logger.Logger.Info("shutdown signal received, draining")
	}

	// The drain gets its OWN context. ctx is already cancelled - that is why we are
	// here - and passing it to Shutdown makes Shutdown return immediately and cut every
	// in-flight request, which is precisely what this function exists to prevent.
	drainCtx, cancel := context.WithTimeout(context.Background(), config.GlobalConfig.ShutdownTimeout)
	defer cancel()

	if err := server.Shutdown(drainCtx); err != nil {
		// Requests still running at the deadline get cut. Loud, not silent: this line
		// tells you the grace period is too short or an endpoint is too slow.
		logger.Logger.Errorf("drain exceeded %s: %v", config.GlobalConfig.ShutdownTimeout, err)
		return 1
	}
	logger.Logger.Info("http drained")
	return 0
}
```

Read that file top to bottom and you know the process: what it reads, what it
connects to, what runs in the background, and the exact order everything stops in.

### No migrations, no seeds, no backfills in `main`

`main` does not call `database.MigrateDB`, does not seed, and does not run a data
backfill. Not in local, not behind an env flag, not "just this once". Schema and data
changes run in `cmd/migration`, once per deploy, before any replica boots;
`references/data-layer.md` has the command and the cost of doing it any other way.

The short version of that cost, because it is the reason this rule exists: ten
replicas rolling at once is ten processes racing the same `ALTER TABLE`, and a
migration that fails on boot and logs "continue anyway" leaves new code serving
against an old schema, which reports healthy and fails on the first request that
reads the new column.

### No signal handler anywhere else

```go
// ✘ database/pgsql.go, being helpful.
go func() {
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	<-c
	sqlDB, _ := Db.DB()
	sqlDB.Close()
	os.Exit(0)
}()
```

Trace a deploy through that. The orchestrator sends SIGTERM. This goroutine and
`main`'s handler both receive it. This one closes the pool and calls `os.Exit(0)`
within microseconds, so:

- `server.Shutdown` never runs. Every in-flight request is cut mid-write; the client
  sees a reset connection, retries, and a non-idempotent write happens twice.
- Requests that were not cut yet hit a closed pool and return `sql: database is
  closed` as a 500 for the few microseconds before the exit.
- `os.Exit` skips every deferred function in every goroutine. Workers mid-tick are
  abandoned with their rows half-written.
- It exits 0. The orchestrator records a clean stop. Nothing in any log says the
  process was killed by its own database package.

**A package that owns a resource exposes `Close`. It never decides when to call it.**
`database.CloseDatabase()` exists and `main` calls it last. That split is the whole
fix.

## Config: read once, typed, explicitly

```go
// internal/config/config.go
package config

import (
	"time"

	"example.com/users-service/internal/helpers"
	"example.com/users-service/pkg/logger"

	"github.com/joho/godotenv"
)

type Config struct {
	Env      string
	Port     string
	LogLevel string

	DBHost     string
	DBPort     string
	DBUser     string
	DBPassword string
	DBName     string
	DBMaxConns int

	JwtSecret                     string
	InternalServicesWebhookSecret string

	ActivitiesServiceBaseURL string

	WriteTimeout      time.Duration
	ShutdownTimeout   time.Duration
	WorkerStopTimeout time.Duration
}

// GlobalConfig is one of the three process-wide handles (see "The three globals").
// It is assigned exactly once, by LoadConfig, and never reassigned.
var GlobalConfig *Config

// LoadConfig is called as the FIRST line of every main: cmd/main.go, cmd/migration,
// cmd/worker. It is deliberately not called from init().
func LoadConfig() {
	if err := godotenv.Load(".env"); err != nil {
		// Normal in a container: the orchestrator injects the environment.
		logger.Logger.Info("no .env file, using the process environment")
	}

	GlobalConfig = &Config{
		Env:      helpers.GetOsEnvOrPanic("ENV"),
		Port:     helpers.GetOsEnvOrPanic("PORT"),
		LogLevel: helpers.GetOsEnvOrDefault("LOG_LEVEL", "info"),

		DBHost:     helpers.GetOsEnvOrPanic("DB_HOST"),
		DBPort:     helpers.GetOsEnvOrPanic("DB_PORT"),
		DBUser:     helpers.GetOsEnvOrPanic("DB_USERNAME"),
		DBPassword: helpers.GetOsEnvOrPanic("DB_PASSWORD"),
		DBName:     helpers.GetOsEnvOrPanic("DB_DATABASE"),
		DBMaxConns: helpers.GetOsEnvIntOrDefault("DB_MAX_CONNS", 10),

		// Secrets have NO default. Ever. See the rules below.
		JwtSecret:                     helpers.GetOsEnvOrPanic("JWT_SECRET"),
		InternalServicesWebhookSecret: helpers.GetOsEnvOrPanic("INTERNAL_SERVICES_WEBHOOK_SECRET"),

		// Peer URLs have NO default either: a default is a hostname, and the only
		// hostname anyone ever types as a default is production's.
		ActivitiesServiceBaseURL: helpers.GetOsEnvOrPanic("ACTIVITIES_SERVICE_BASE_URL"),

		WriteTimeout:      helpers.GetOsEnvDurationOrDefault("HTTP_WRITE_TIMEOUT", 30*time.Second),
		ShutdownTimeout:   helpers.GetOsEnvDurationOrDefault("SHUTDOWN_TIMEOUT", 20*time.Second),
		WorkerStopTimeout: helpers.GetOsEnvDurationOrDefault("WORKER_STOP_TIMEOUT", 10*time.Second),
	}
}
```

```go
// internal/helpers/osenv.helper.go
package helpers

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// GetOsEnvOrPanic names the key it wanted. "Environment variable DB_HOST is not set"
// ends the incident at the first log line. A bare "invalid configuration" starts a
// bisect.
func GetOsEnvOrPanic(key string) string {
	if value, ok := os.LookupEnv(key); ok && value != "" {
		return value
	}
	panic("Environment variable " + key + " is not set")
}

func GetOsEnvOrDefault(key, defaultValue string) string {
	if value, ok := os.LookupEnv(key); ok && value != "" {
		return value
	}
	return defaultValue
}

// Absent means default. Present-and-garbage means panic, never the default: falling
// back on a typo means the deploy silently ignores the value someone typed, runs on a
// number nobody chose, and reports success.
func GetOsEnvIntOrDefault(key string, defaultValue int) int {
	raw, ok := os.LookupEnv(key)
	if !ok || raw == "" {
		return defaultValue
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		panic(fmt.Sprintf("Environment variable %s=%q is not an integer", key, raw))
	}
	return n
}

func GetOsEnvDurationOrDefault(key string, defaultValue time.Duration) time.Duration {
	raw, ok := os.LookupEnv(key)
	if !ok || raw == "" {
		return defaultValue
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		panic(fmt.Sprintf("Environment variable %s=%q is not a duration (want 30s, 5m)", key, raw))
	}
	return d
}

func GetOsEnvBoolOrDefault(key string, defaultValue bool) bool {
	raw, ok := os.LookupEnv(key)
	if !ok || raw == "" {
		return defaultValue
	}
	b, err := strconv.ParseBool(raw)
	if err != nil {
		panic(fmt.Sprintf("Environment variable %s=%q is not a boolean", key, raw))
	}
	return b
}
```

The rules this encodes:

- **Panic at boot, not at request time.** A required key that is missing kills the
  process before it accepts a connection. The alternative is a process that reports
  healthy and fails on the first request that reaches the unconfigured path.
- **A secret never has a default.** Not a test key, not "the staging one", not an
  empty string that a middleware treats as "auth disabled". A default secret is a
  secret committed to the repository, and it is the value production runs on the day
  somebody forgets to set the variable. A secret that is genuinely optional (a
  feature not every environment has) defaults to `""` and the code that uses it
  treats `""` as **off**, and fails closed.
- **A peer URL never defaults to production.** An unset variable on staging then
  makes staging call production, with no error and no log line, and staging's test
  data lands in a customer's account.
- **Every field is typed at the boundary.** `WriteTimeout` is a `time.Duration`.
  Nobody downstream parses anything, so nobody downstream parses it differently.
- **No `os.Getenv` in a call path. Ever.** Not in a middleware, not in a route setup
  function, not behind a feature flag check in a service. A flag read in a call path
  is invisible from `LoadConfig`, unreachable from a test, and turns a boot error into
  somebody's afternoon. Every flag is a `Config` field.
- **`LoadConfig` is called, not run by `init()`.** An `init()` runs on import, so
  every test in every package that imports `config` - which is every resource, through
  `database` - needs the full production environment set or it panics before the
  first test function runs. The suite becomes "needs a .env", which becomes "only runs
  on one laptop". `cmd/migration` already calls `LoadConfig` explicitly; every `main`
  does the same, as its first line.

## The three globals

This blueprint has exactly three package-level handles:

| Handle | Set by | When |
|---|---|---|
| `config.GlobalConfig` | `config.LoadConfig()` | first line of every `main` |
| `logger.Logger` | the logger package's `init()` | import time; it cannot fail |
| `database.Db` | `database.LoadDatabase()` | after config, before `SetupRouter` |

They are globals on purpose. Every service in the fleet reaches them the same way, so
a reader who has seen one service has seen the plumbing of all of them; and a service
method that needs the database calls `database.Db` instead of threading a handle
through every constructor in the graph.

The price is real and it is paid in three places, so the rules that keep them safe are
not optional:

- **Assigned once, at boot, before anything reads them. Never reassigned.** A global
  that can change while requests run is shared mutable state with no lock, and the
  race detector only finds it if a test happens to do both at once.
- **Never closed by the package that holds them.** `CloseDatabase` exists; only
  `main` calls it.
- **Tests set them deliberately**, through one test helper per package that needs
  them (`database.Db = testDB` in a `TestMain`), never by importing a package whose
  `init()` reaches for a real database.
- **There is no fourth.** A package-level `var` holding a client, a cache, a worker or
  a token provider is a dependency `SetupRouter` cannot see, so the one function that
  is supposed to describe the service has stopped describing it. Those are
  constructed in `SetupRouter` and handed in.

The logger is the one handle set by `init()`, and only because its `init()` cannot
fail and reads nothing required:

```go
// pkg/logger/logger.go
package logger

import (
	"os"

	"github.com/sirupsen/logrus"
)

var Logger *logrus.Logger

func init() {
	Logger = logrus.New()
	Logger.SetOutput(os.Stdout)
	Logger.SetFormatter(&logrus.JSONFormatter{})
	Logger.SetLevel(logrus.InfoLevel)
}

// SetLevel is called by main once config is loaded. An unparseable level stays at
// info and says so, rather than panicking over a log setting.
func SetLevel(level string) {
	l, err := logrus.ParseLevel(level)
	if err != nil {
		Logger.Warnf("unknown LOG_LEVEL %q, staying at info", level)
		return
	}
	Logger.SetLevel(l)
}
```

## `SetupRouter` is the composition root

`main` owns the process; `SetupRouter` owns the object graph. Every client, service,
handler and worker in the service is constructed in this one function, in dependency
order, and handed to whatever needs it.

```go
// internal/routes/routes.go
package routes

import (
	"context"
	"net/http"
	"time"

	"example.com/users-service/internal/config"
	"example.com/users-service/internal/helpers"
	"example.com/users-service/internal/middleware"
	holidaysresource "example.com/users-service/internal/resources/holidays_resource"
	reconcilerresource "example.com/users-service/internal/resources/reconciler_resource"
	"example.com/users-service/pkg/worker"
	activitiesclient "example.com/users-service/pkg/activities_client"

	"github.com/gin-gonic/gin"
)

// BackgroundWorker is what main needs from anything that runs without a request:
// start it under the root context, and stop it under a bound.
type BackgroundWorker interface {
	Start(ctx context.Context)
	Stop(timeout time.Duration)
}

// SetupRouter builds the whole service. Read it top to bottom and you know every
// dependency every resource has. If it is not constructed here, the service does not
// have it.
func SetupRouter(router *gin.Engine) []BackgroundWorker {
	setDefaultRoutes(router)

	v1 := router.Group("/v1")
	setupSwagger(v1)

	// 1. Clients: peers and vendors. Leaves first.
	activitiesClient := activitiesclient.NewActivitiesClient(
		config.GlobalConfig.ActivitiesServiceBaseURL,
		config.GlobalConfig.InternalServicesWebhookSecret,
	)

	// 2. Services, in dependency order. A service that needs another service is
	// constructed after it, and receives it as a parameter.
	holidaysService, err := holidaysresource.NewHolidaysService(activitiesClient)
	must("holidays service", err)

	reconcilerService, err := reconcilerresource.NewReconcilerService(activitiesClient)
	must("reconciler service", err)

	// 3. Handlers.
	holidaysHandler, err := holidaysresource.NewHolidaysHandler(holidaysService)
	must("holidays handler", err)

	// 4. Routes. Auth is applied to the GROUP, never route by route: a per-route
	// middleware list is a list someone appends to, and the route they forget is
	// public forever with nothing to notice it.
	internal := v1.Group("", middleware.InternalServicesAuth())
	user := v1.Group("", middleware.RequireValidJWT())

	setupHolidaysRoutes(internal.Group("/holidays"), user.Group("/me/holidays"), holidaysHandler)

	// 5. Background work: constructed here, started and stopped by main. Never
	// `go x.Run(context.Background())` from this function - see below.
	return []BackgroundWorker{
		worker.NewTicker("crm-reconciler", time.Hour, reconcilerService.ReconcileAll),
	}
}

// must turns a construction error into a boot failure that names the thing that
// failed. Construction is the one place a panic is the honest move: nothing is
// listening yet, so a refused boot costs one failed deploy and nothing else.
func must(what string, err error) {
	if err != nil {
		panic("Failed to initialise " + what + ": " + err.Error())
	}
}

func setDefaultRoutes(router *gin.Engine) {
	// Liveness checks the process and nothing else. A probe that pings the database
	// restarts every replica during a database blip, which turns a thirty-second
	// wobble into a full outage that you caused.
	router.GET("/healthz", func(c *gin.Context) {
		c.JSON(helpers.RespondOk("alive", &gin.H{"status": "ok"}))
	})
	router.NoRoute(func(c *gin.Context) {
		c.JSON(helpers.RespondError("route not found", nil, http.StatusNotFound))
	})
}

func setupHolidaysRoutes(internal, user *gin.RouterGroup, h *holidaysresource.HolidaysHandlerImpl) {
	// Service-to-service: the caller authenticated with the internal secret and
	// derived user_id from a credential of its own.
	internal.GET("/user/:user_id", h.ListHolidays)
	internal.POST("/user/:user_id", h.AddHoliday)
	internal.DELETE("/user/:user_id/:holiday_id", h.RemoveHoliday)

	// User-facing: identity from the JWT, so there is no user_id in the path at all.
	user.GET("", h.ListMyHolidays)
}
```

The rules this encodes:

- **Clients, then services, then handlers, then routes, then workers.** The order is
  the dependency graph, written down. A service constructed before the client it needs
  does not compile, which is the cheapest correctness check this file has.
- **A construction error panics at boot, naming the resource.** `must` exists so that
  every constructor is handled the same way. `logger.Fatalf` is not a substitute: it
  calls `os.Exit` and skips every defer, including the ones `main` is about to rely on.
- **A degraded dependency is a decision, written down.** If a resource genuinely can
  run without a client (a payment gateway that is not configured in local), its
  constructor accepts a nil and the service returns `contracts.ErrUnavailable` from
  the methods that needed it. What is banned is the third option: logging the error,
  assigning nil, and carrying on, so the first request to need the client is a
  nil-pointer panic.
- **`SetupRouter` starts nothing.** No goroutine, no ticker, no provisioning loop.
  `go reconciler.Run(context.Background(), ...)` in this function is a goroutine with no
  owner: no context that shutdown cancels, no `Stop`, no bound. It is still mid-write
  when `CloseDatabase` runs, and its last act is an error against a closed pool.
  Construct it here, return it, and `main` starts it under the root context and stops
  it in reverse order.
- **One route-setup function per resource**, `setup<Name>Routes(group, handler)`, so
  the URL table for a resource is one function and a reviewer sees its whole surface
  at once.

## Shutdown: stop accepting, drain, stop workers, close

Two distinct steps that get conflated. **Cancelling the context asks; `Stop` waits for
the answer.** A shutdown that only cancels is a race you usually win.

```
SIGTERM                -> ctx cancelled: workers start no new tick, and their current
                          tick's context is cancelled, while the HTTP drain runs
server.Shutdown(...)   -> listener closed; in-flight requests finish under ShutdownTimeout
workers[n-1].Stop(...) -> WAITS until the last worker started has actually exited
...
workers[0].Stop(...)   -> WAITS until the first worker started has actually exited
CloseDatabase()        -> LAST, because everything above needed it until now
os.Exit(code)          -> nothing deferred is left to skip
```

The cancel reaches the workers at the signal, so they usually wind down while the
HTTP drain is still running, and `Stop` finds them already gone. `Stop` is still
required: it is the only thing that proves a worker has exited before the database it
is writing to closes.

**Budget the total.** The orchestrator kills at its own grace period: Docker's default
is ten seconds. `ShutdownTimeout`, plus `WorkerStopTimeout` times the number of
workers, plus any readiness delay, must fit inside that period with room to spare. If
it does not, the careful ordering is decoration: SIGKILL arrives partway down the list
and `CloseDatabase` never runs. Set the orchestrator's stop grace period explicitly, to
a number you computed from these three.

If the platform routes by a readiness probe, add one: a `/readyz` that returns 503
from the moment the signal arrives, and a short sleep before `server.Shutdown` so the
load balancer stops routing while the listener is still open. Without it, the requests
the balancer sends in the gap hit a closed listener and the client sees a 502 that
the deploy caused and the code gets blamed for.

## What an unordered exit actually costs

`os.Exit(0)` on a signal, or no signal handling at all, is not "a faster restart". It
is this:

- A handler wrote its side effect and had not yet written its response. The socket
  dies. The client sees a network error, retries, and the effect happens twice.
  Nothing logged that. It surfaces days later as a duplicate charge, and nothing
  points back at the deploy that caused it.
- A worker had leased a job and had not acked it. It redelivers and runs twice, which
  is survivable only because the handler is idempotent, and it is only idempotent if
  someone said this would happen (`references/background-work.md`).
- A batch was halfway through writing rows outside a transaction. Half exist. No
  record says which half.

None of these produce an error log. An unordered exit does not fail, it truncates, and
truncated work is damage with no signal attached.

## Refactor order

Bringing an existing service to this lifecycle, one landable commit at a time. The
order matters more here than anywhere else in the blueprint.

1. **Create `cmd/migration` and wire it into the deploy as a pre-deploy job.** It runs
   `MigrateDB` and the seeds. Ship it and watch it run on a real deploy **while boot
   still migrates too** (both are idempotent, so running twice is safe). Do not move to
   step 2 until a deploy has shown the job's exit code gating the rollout.
2. **Delete migrations, seeds and backfills from `main`.** Only now: removing the boot
   migration before the job exists ships a deploy that changes no schema at all, and
   the first request that reads the new column is a 500.
3. **Make `LoadConfig` explicit** as the first line of every `main`, and delete the
   `init()` that called it.
4. **Move every `os.Getenv` in a call path into `Config`**, one package per commit.
5. **Return background loops from `SetupRouter`** as `BackgroundWorker`s instead of
   starting them there, one loop per commit. Each one needs a `Start`/`Stop`; the
   `worker.Ticker` in `references/background-work.md` is the default.
6. **Add `CloseDatabase` and delete the signal goroutine from `pgsql.go`**, in the same
   commit as adding `signal.NotifyContext` and `serve` to `main`. Never one without the
   other: removing the database's handler before `main` has one leaves a process that
   ignores SIGTERM until SIGKILL.
