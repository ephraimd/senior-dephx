# The data layer

Where the database is opened, what a table looks like in Go, how a query is allowed to
fail, what a transaction may hold open, and the one place the schema is allowed to
change.

The spine says one global handle, models in one place, every query scoped to its
tenant, and migrations only from `cmd/migration`. This is the code that makes those
true.

## Queries live in the service, decisions are testable without one

There is no repository layer in this house style. The service owns its queries: it
calls `database.Db` through GORM, inside `SafeDBQuery`. A handler never imports
`database`, and a helper never queries.

What keeps that from welding every rule to a database is one habit: **a decision that
needs no I/O is a pure function, and the service calls it.**

```go
// ✘ The rule and the query in one method. Testing "you cannot remove a holiday that
// has already passed" now needs a database, a schema and a fixture, so the test is
// slow, so it gets skipped, so the rule is untested.
func (s *HolidaysServiceImpl) RemoveHoliday(parentUserID, holidayID int) error {
	var h model.UserHoliday
	if err := database.Db.Scopes(helpers.TenantScope(parentUserID)).First(&h, holidayID).Error; err != nil {
		return err
	}
	if h.HolidayDate.Before(time.Now().Truncate(24 * time.Hour)) {
		return contracts.ErrHolidayInPast
	}
	...
}

// ✔ The rule takes no dependencies. Its test is a table of dates that runs in a
// millisecond, and the bulk-delete endpoint can call it too instead of copying it.
func removable(h model.UserHoliday, today time.Time) error {
	if h.HolidayDate.Before(today) {
		return contracts.WithDetail(contracts.ErrHolidayInPast, "%s has already passed", h.HolidayDate.Format(dateLayout))
	}
	return nil
}
```

## `pgsql.go`: one handle, opened once, closed by `main`

```go
// database/pgsql.go
package database

import (
	"fmt"
	"log"
	"os"
	"time"

	"example.com/users-service/internal/config"
	"example.com/users-service/internal/contracts"
	"example.com/users-service/pkg/logger"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	gormlogger "gorm.io/gorm/logger"
)

// Db is one of the three process-wide handles. LoadDatabase assigns it once; nothing
// reassigns it; CloseDatabase is called by main and by nothing else.
var Db *gorm.DB

func LoadDatabase() {
	cfg := config.GlobalConfig

	sslmode := "disable"
	if cfg.Env == string(contracts.PROD) || cfg.Env == string(contracts.TEST) {
		sslmode = "require"
	}
	dsn := fmt.Sprintf("host=%s user=%s password=%s dbname=%s port=%s sslmode=%s TimeZone=UTC",
		cfg.DBHost, cfg.DBUser, cfg.DBPassword, cfg.DBName, cfg.DBPort, sslmode)

	db, err := gorm.Open(postgres.New(postgres.Config{
		DSN: dsn,
		// Required when anything between this process and Postgres pools in
		// transaction mode (PgBouncer, a managed pooler): the extended protocol's
		// session-level prepared statements break there, intermittently, under load.
		PreferSimpleProtocol: true,
	}), &gorm.Config{
		// Unique violations come back as gorm.ErrDuplicatedKey and foreign-key
		// violations as gorm.ErrForeignKeyViolated, so a service can map them to a
		// sentinel with errors.Is instead of parsing SQLSTATE text.
		TranslateError: true,
		Logger: gormlogger.New(log.New(os.Stdout, "\r\n", log.LstdFlags), gormlogger.Config{
			SlowThreshold: 200 * time.Millisecond,
			LogLevel:      gormLogLevel(cfg.Env),
			// Bound values stay out of the slow-query and error logs. Without this, the
			// log line for a slow login query carries the email and the password hash.
			ParameterizedQueries: true,
		}),
	})
	if err != nil {
		// Panic, at boot, before anything listens. gorm.Open pings, so a wrong
		// password fails the deploy here instead of a user's first request.
		panic(fmt.Sprintf("Failed to connect to DB: %s", err))
	}

	sqlDB, err := db.DB()
	if err != nil {
		panic(fmt.Sprintf("Failed to get DB connection: %s", err))
	}
	sqlDB.SetMaxOpenConns(cfg.DBMaxConns)
	sqlDB.SetMaxIdleConns(cfg.DBMaxConns / 2)
	sqlDB.SetConnMaxLifetime(5 * time.Minute)
	sqlDB.SetConnMaxIdleTime(2 * time.Minute)

	Db = db
	logger.Logger.Infof("database connected (sslmode=%s, max_conns=%d)", sslmode, cfg.DBMaxConns)
}

// CloseDatabase is called by main, last, after the server has drained and every
// worker has stopped. This package never decides when that is: no signal handler,
// no os.Exit. See references/composition-and-lifecycle.md.
func CloseDatabase() {
	if Db == nil {
		return
	}
	sqlDB, err := Db.DB()
	if err != nil {
		logger.Logger.Errorf("close database: %v", err)
		return
	}
	if err := sqlDB.Close(); err != nil {
		logger.Logger.Errorf("close database: %v", err)
	}
}

func gormLogLevel(env string) gormlogger.LogLevel {
	switch env {
	case string(contracts.PROD):
		return gormlogger.Silent
	case string(contracts.TEST):
		return gormlogger.Error
	default:
		return gormlogger.Warn
	}
}
```

### The pool numbers are a share of a global budget

Every number above has a default, and **a default pool is a number nobody chose that
you discover under load.**

- **`SetMaxOpenConns`. Default: unlimited.** Unlimited opens one connection per
  concurrent query until the server's `max_connections` refuses the next one, and it
  refuses it for every service on that cluster, including the psql session you were
  about to open to find out why. `replicas x DBMaxConns`, summed over every service on
  the cluster, has to fit under `max_connections` with room for the admin connection
  you will need during the incident. Nobody owns that sum, which is why it is the one
  that gets exceeded; write it down where the services' configs live.
- **`SetMaxIdleConns`.** Below `MaxOpen` returns slots to a shared pooler between
  bursts, at the price of a reconnect per burst. Equal to `MaxOpen` keeps a grown pool
  grown. On a cluster many services share, returning slots wins; on a dedicated one,
  keeping them does. Either is a choice; leaving the default (2) is not.
- **`SetConnMaxLifetime`. Default: forever.** A connection that never dies outlives
  every proxy and pooler in front of it. After a failover the pool still holds
  connections to the old primary, now a replica, and every write fails until a
  restart.
- **`SetConnMaxIdleTime`.** Returns a burst's connections once the burst is over.

## Models: the table, in Go, and nothing else

```go
// database/model/user_holiday.go
package model

import "time"

const TableNameUserHoliday = "user_holidays"

// UserHoliday is the row. It is not a DTO: it never goes on the wire in either
// direction (references/layout-and-naming.md).
type UserHoliday struct {
	ID int `gorm:"column:id;primaryKey;autoIncrement:true" json:"id"`

	// The tenant leads every index this table has. An index on (holiday_date) alone
	// serves a tenant-scoped query by scanning other tenants' rows and discarding them:
	// correct, and slower for every tenant as any one of them grows.
	ParentUserID int `gorm:"column:parent_user_id;not null;uniqueIndex:uq_user_holidays_tenant_date,priority:1" json:"parent_user_id"`

	HolidayDate time.Time `gorm:"column:holiday_date;type:date;not null;uniqueIndex:uq_user_holidays_tenant_date,priority:2" json:"holiday_date"`
	Name        string    `gorm:"column:name;size:120;not null;default:''" json:"name"`
	IsActive    bool      `gorm:"column:is_active;not null;default:true" json:"is_active"`
	CreatedAt   time.Time `gorm:"column:created_at;autoCreateTime" json:"created_at"`
	UpdatedAt   time.Time `gorm:"column:updated_at;autoUpdateTime" json:"updated_at"`
}

func (*UserHoliday) TableName() string { return TableNameUserHoliday }
```

The rules:

- **Explicit `gorm:"column:..."` and `json:"..."` on every field.** GORM's naming
  strategy is a function nobody reads; `column:` is the column, in the struct, where a
  reviewer sees it. The `json` tag is for logs and debugging, not the wire.
- **A `TableName` constant and a `TableName()` method.** The constant is what raw SQL
  in `db_migrate.go` and a peer's shared model use, so the table's name has one
  spelling.
- **Tenancy columns on every tenant-owned table**: `parent_user_id`, and
  `owner_account_id` where rows belong to an account within the tenant. A row that
  cannot say which tenant it belongs to is a row the next reader has to guess about,
  and a row that has travelled into a job payload or a cache has left the query that
  scoped it.
- **Every uniqueness rule the business has is a unique index here, led by the tenant.**
  "One holiday per date per user" exists only if `uq_user_holidays_tenant_date` does.
  An `if` in Go is not a constraint (see "Idempotent writes").
- **Hard deletes by default.** A soft delete is a decision someone makes for a reason
  (an audit duty, an undo), and when it is made the column is `gorm.DeletedAt`, never a
  hand-rolled `*time.Time DeletedAt`. GORM scopes `gorm.DeletedAt` out of every query
  automatically; a hand-rolled column has to be filtered with `deleted_at IS NULL` by
  hand in every query, and the one that forgets serves deleted rows. Soft deletes also
  turn every unique index into a partial one, and every upsert's conflict target with
  it.

## `SafeDBQuery`: a panic becomes an error, and the error is returned

Every query goes through `SafeDBQuery`; every multi-statement write goes through
`SafeDBTransaction`.

```go
// internal/helpers/db.helper.go
package helpers

import (
	"errors"
	"fmt"
	"runtime/debug"

	"example.com/users-service/pkg/logger"

	"gorm.io/gorm"
)

// SafeDBQuery turns a panic inside a query into a returned error instead of letting it
// unwind past the caller. The named return is the whole mechanism: recover() alone
// stops the unwind and returns zero values, so without the assignment a panicking
// query returns a nil error and the caller carries on believing the write succeeded.
func SafeDBQuery(action func() error) (err error) {
	defer func() {
		if r := recover(); r != nil {
			// The stack goes to the log now, because the frames it names are gone the
			// moment this function returns.
			logger.Logger.WithField("stack", string(debug.Stack())).Errorf("panic in database call: %v", r)
			err = fmt.Errorf("internal database error: %v", r)
		}
	}()
	return action()
}

// SafeDBTransaction runs fn inside one transaction with the same panic guard. fn
// receives tx and must use tx for every statement; see "Transactions".
func SafeDBTransaction(db *gorm.DB, fn func(tx *gorm.DB) error) error {
	return SafeDBQuery(func() error { return db.Transaction(fn) })
}

func IsNotFound(err error) bool         { return errors.Is(err, gorm.ErrRecordNotFound) }
func IsDuplicateKey(err error) bool     { return errors.Is(err, gorm.ErrDuplicatedKey) }
func IsForeignKeyViolated(err error) bool { return errors.Is(err, gorm.ErrForeignKeyViolated) }
```

**Why a query needs its own panic boundary when Recovery already exists.** Recovery is
per request; a worker's recover is per tick. Both are backstops for the process, and
both are too coarse. A nil map in a row mapper on job 3 of 32 unwinds past the whole
batch, so jobs 4 to 32 are never handled and the same poison row kills the same batch
on the next tick. Inside `SafeDBQuery`, the panic is an error for job 3, which gets its
retry, and the other 31 go through.

**"Safe" is about the panic and only the panic.** Every call site returns its error.

```go
// ✘ The name said safe.
var h model.UserHoliday
helpers.SafeDBQuery(func() error {
	return database.Db.Scopes(helpers.TenantScope(parentUserID)).First(&h, id).Error
})
return toHolidayResponseDTO(h) // id 0, date 0001-01-01, on a timeout, a miss, or a panic
```

That returns a zero holiday on a connection reset, a missing row, and a panic, and the
caller cannot tell any of them from a real row. If a linter can enforce one thing in
this repo, enforce that a `SafeDBQuery` result is never discarded.

### Driver errors become sentinels, in the service, once

`gorm.ErrRecordNotFound` is not a domain concept, and the layer above does not know
what to do with it. The service translates at the call that produced it:

```go
func (s *HolidaysServiceImpl) GetHoliday(parentUserID, holidayID int) (model.UserHoliday, error) {
	var h model.UserHoliday
	err := helpers.SafeDBQuery(func() error {
		return database.Db.Scopes(helpers.TenantScope(parentUserID)).First(&h, holidayID).Error
	})
	switch {
	case err == nil:
		return h, nil
	case helpers.IsNotFound(err):
		// Another tenant's id lands here too, which is the point: the client gets the
		// same 404 for "does not exist" and "is not yours" (references/http-layer.md).
		return model.UserHoliday{}, fmt.Errorf("get holiday %d: %w", holidayID, contracts.ErrHolidayNotFound)
	default:
		// Unclassified: RespondServiceError makes it a 500 with a reference, and the
		// driver's text stays in the log.
		return model.UserHoliday{}, fmt.Errorf("get holiday %d: %w", holidayID, err)
	}
}
```

- `gorm.ErrRecordNotFound` becomes the resource's `NotFound` sentinel.
- `gorm.ErrDuplicatedKey` becomes the resource's `Conflict` sentinel, when the
  duplicate is something the user did. The constraint name goes in the `%w` context
  for the log; it never reaches the client.
- Everything else is wrapped with context and returned. It is a 500, and it should be.

## Transactions: one function, one handle

```go
// ✔ Both rows, or neither.
err := helpers.SafeDBTransaction(database.Db, func(tx *gorm.DB) error {
	if err := tx.Create(&stage).Error; err != nil {
		return fmt.Errorf("create stage: %w", err)
	}
	action.StageID = stage.ID
	if err := tx.Create(&action).Error; err != nil {
		return fmt.Errorf("create stage action: %w", err)
	}
	return nil
})
```

**Inside the callback, every statement uses `tx`. `database.Db` inside a transaction
callback is a bug**, and the most common one this layer has: the statement runs on a
different pooled connection, outside the transaction, commits on its own immediately,
and is not rolled back when the transaction fails. It also needs a second connection
while the first is held, so under load the transaction waits on a pool it is itself
exhausting.

A helper or a service method that must be able to join a caller's transaction takes
the handle as a parameter, `db *gorm.DB`, and the caller passes `tx` or `database.Db`.
One method then serves both callers; the alternative is `Create` and `CreateTx`, two
copies of one statement that drift.

### Nothing that can be slow goes inside one

**No network call. No call to a peer service. No vendor API. No Redis enqueue. No
`time.Sleep`.** Not "avoid where practical": none.

Trace it when the peer is having a bad afternoon. Each request holds one pooled
connection and one open transaction for ten seconds. At `DBMaxConns` concurrent
requests the pool is empty, and **every other endpoint in the service blocks waiting
for a connection**, including the ones that never touch that peer. A third party's
outage is now yours, amplified. Each of those transactions also holds its row locks
and sits `idle in transaction`, which stops autovacuum cleaning dead rows anywhere in
the database.

The two correct shapes are: commit, then do the slow thing (Pattern A in
`references/background-work.md`); or write a row the slow thing will pick up, in the
same transaction (Patterns B and C). The only thing allowed inside a transaction is
more of the same database.

## Idempotent writes

**Read-then-write is a race with itself.**

```go
// ✘ Correct in a single-threaded test. Wrong the moment there are two of anything.
var existing model.UserHoliday
err := database.Db.Where("parent_user_id = ? AND holiday_date = ?", uid, d).First(&existing).Error
if err == nil {
	return existing, nil
}
// The window is right here. A retried request, a double-click, a second replica: both
// ran the same select, both got no row, both insert.
return holiday, database.Db.Create(&holiday).Error
```

The window does not need replicas. A client whose first attempt timed out at the load
balancer while the insert was still running sends its retry straight into it. With a
unique index, one insert wins and the other gets `ErrDuplicatedKey`; without one, both
succeed, and the user has two holidays on one date forever, half of every report
counting one and half the other.

```go
// ✔ One statement. The unique index is the arbiter; there is no window to lose.
func (s *HolidaysServiceImpl) AddHoliday(
	parentUserID int,
	input holidaysresource_dto.CreateHolidayDTO,
) (model.UserHoliday, error) {
	date, err := parseHolidayDate(input.HolidayDate) // returns a contracts.InvalidFields on garbage
	if err != nil {
		return model.UserHoliday{}, err
	}
	holiday := model.UserHoliday{
		ParentUserID: parentUserID,
		HolidayDate:  date,
		Name:         input.Name,
		IsActive:     true,
	}
	err = helpers.SafeDBQuery(func() error {
		return database.Db.Clauses(clause.OnConflict{
			// Must match a real unique index, column for column. It is not a hint:
			// Postgres answers a mismatch at runtime, on the first duplicate, which is
			// the first time anyone runs this path twice, which is production.
			Columns:   []clause.Column{{Name: "parent_user_id"}, {Name: "holiday_date"}},
			DoUpdates: clause.AssignmentColumns([]string{"name", "is_active", "updated_at"}),
		}).Create(&holiday).Error
	})
	if err != nil {
		return model.UserHoliday{}, fmt.Errorf("add holiday: %w", err)
	}
	return holiday, nil
}
```

- **`DoUpdates`, not `DoNothing`.** `ON CONFLICT DO NOTHING` returns no row on a
  conflict, so the struct comes back with `ID` 0 and the handler returns a holiday that
  does not exist. If there is genuinely nothing to update, update something inert
  (`updated_at`) so the row comes back.
- **The constraint is the correctness boundary; a Go check is an optimisation.** A
  `First` before a `Create` is allowed, for a better message on the common path. It is
  not a guarantee. If the invariant matters and there is no unique index for it, the
  invariant does not exist yet. Write the index first, in the model's tags or in
  `db_migrate.go`.
- **Check `RowsAffected` where zero is a failure.** An `Update` or `Delete` that
  matched nothing returns `nil`; ignoring `RowsAffected` reports "removed" for a
  holiday that never existed or belongs to someone else.

```go
res := database.Db.Scopes(helpers.TenantScope(parentUserID)).Delete(&model.UserHoliday{}, holidayID)
if res.Error != nil {
	return fmt.Errorf("remove holiday %d: %w", holidayID, res.Error)
}
if res.RowsAffected == 0 {
	return fmt.Errorf("remove holiday %d: %w", holidayID, contracts.ErrHolidayNotFound)
}
```

## Migrations run in one function, from one command, before the deploy

**One function holds every schema change, in one order.** `database.MigrateDB` does
three things, always in this sequence:

1. **Renames and other changes AutoMigrate cannot infer**, first. AutoMigrate compares
   struct tags to the live schema and adds what is missing; it does not detect a
   rename. Rename a field's column tag without a prior `RenameColumn` and AutoMigrate
   adds an empty new column beside the old one, and the data stays behind in a column
   nothing reads.
2. **`AutoMigrate` over every model this service owns.**
3. **Idempotent raw SQL** for what struct tags cannot express: partial indexes,
   expression indexes, check constraints, a `CONCURRENTLY` build. Every statement is
   `IF NOT EXISTS` / `IF EXISTS`, and every one's error is checked.

That is one mechanism: one function, one order, one place to read. Two mechanisms (a
tool for tables plus a hand-run psql script for indexes) is two truths about the
schema, and the merge of them exists only in one person's head.

```go
// database/db_migrate.go
package database

import (
	"fmt"

	"example.com/users-service/database/model"
	"example.com/users-service/pkg/logger"

	"gorm.io/gorm"
)

// MigrateDB is called from cmd/migration and from nowhere else: not from main, not
// behind an env flag, not from a test helper that "just needs the schema".
func MigrateDB(db *gorm.DB) error {
	// 1. Renames. Each guarded, so the second run is a no-op.
	if db.Migrator().HasColumn(&model.CrmConfig{}, "legacy_field_key") &&
		!db.Migrator().HasColumn(&model.CrmConfig{}, "crm_field_key") {
		if err := db.Migrator().RenameColumn(&model.CrmConfig{}, "legacy_field_key", "crm_field_key"); err != nil {
			return fmt.Errorf("rename crm_configs.legacy_field_key: %w", err)
		}
	}

	// 2. Tables and columns. Every model THIS service owns, and only those.
	if err := db.AutoMigrate(
		&model.Country{}, // reference data; database_seed fills it
		&model.User{},
		&model.Account{}, // after User: it references users
		&model.UserHoliday{},
		&model.CrmConfig{},
	); err != nil {
		return fmt.Errorf("automigrate: %w", err)
	}

	// 3. What tags cannot say. Each statement idempotent, each error checked: a
	// migration whose Exec error is dropped reports success for an index that does not
	// exist, and the first sign is a full scan in production.
	statements := []struct{ name, sql string }{
		{"uq_crm_configs_oauth_portal", `
			CREATE UNIQUE INDEX IF NOT EXISTS uq_crm_configs_oauth_portal
			    ON crm_configs (oauth_portal_id)
			 WHERE oauth_portal_id IS NOT NULL`},
		{"ck_user_holidays_name_len", `
			DO $$ BEGIN
			    ALTER TABLE user_holidays ADD CONSTRAINT ck_user_holidays_name_len CHECK (char_length(name) <= 120);
			EXCEPTION WHEN duplicate_object THEN NULL;
			END $$`},
	}
	for _, st := range statements {
		if err := db.Exec(st.sql).Error; err != nil {
			return fmt.Errorf("migration %s: %w", st.name, err)
		}
	}

	logger.Logger.Info("migrations applied")
	return nil
}
```

### `cmd/migration` is the only thing that runs it

```go
// cmd/migration/migrate.go
package main

import (
	"fmt"
	"os"

	"example.com/users-service/database"
	"example.com/users-service/database/database_seed"
	"example.com/users-service/internal/config"
	"example.com/users-service/pkg/logger"

	"gorm.io/gorm"
)

// A second binary in the same image. Same code, same models, same commit - which is
// what makes "the migration that ran" and "the code about to run" the same version,
// provably, instead of by convention. The deploy runs it as a one-off job and starts
// the new replicas only if it exits 0.
func main() {
	config.LoadConfig()
	database.LoadDatabase()

	err := migrate()
	database.CloseDatabase()
	if err != nil {
		logger.Logger.Errorf("migration failed: %v", err)
		os.Exit(1) // the deploy stops here, before a single new replica starts
	}
	logger.Logger.Info("migration complete")
}

// migrationLockID is any constant, fixed forever, shared by nothing else.
const migrationLockID = 823144115

func migrate() error {
	// One connection for the whole run, so the advisory lock and the work share a
	// session. The deploy is supposed to run this job once; "supposed to" is not a
	// mechanism, and two concurrent runs racing the same ALTER TABLE is the failure
	// this whole command exists to prevent.
	return database.Db.Connection(func(conn *gorm.DB) error {
		// Blocking, not try: a second run must WAIT and then find nothing to do. Exiting
		// 0 without the migration applied is a lie the rollout believes.
		if err := conn.Exec("SELECT pg_advisory_lock(?)", migrationLockID).Error; err != nil {
			return fmt.Errorf("acquire migration lock: %w", err)
		}
		defer conn.Exec("SELECT pg_advisory_unlock(?)", migrationLockID)

		if err := database.MigrateDB(conn); err != nil {
			return err
		}
		// Seeds and backfills run after the schema they write to exists, in the same
		// job, for the same reason the schema does: once, before any replica boots.
		return database_seed.RunAll(conn)
	})
}
```

### What migrating on boot costs

```go
// ✘ cmd/main.go
err := database.MigrateDB(database.Db)
if err != nil {
	log.Printf("[STARTUP] Migration failed: %v", err)
	// Continue anyway - application might still work with existing tables
}
database_seed.SeedCountries()
database_seed.MigrateSeatData(database.Db)
```

It looks tidy and free. It is neither.

- **Ten replicas roll at once and ten processes migrate.** The first takes an `ACCESS
  EXCLUSIVE` lock for its `ALTER TABLE`; the other nine block on it, sit past their
  startup deadline, get killed, restart, and block again. The rollout stalls and the
  logs say only that the containers are not ready.
- **"Continue anyway" serves new code against an old schema.** The migration failed;
  the process reports healthy; the first request that reads the new column is a 500,
  on every replica, and the only record of why is one log line at boot that scrolled
  away an hour ago.
- **Every replica runs every backfill.** A seat-data backfill that is idempotent runs
  ten times and wastes ten minutes; one that is not quite idempotent runs ten times
  and corrupts the data ten times, concurrently.
- **Nothing can be gated on it.** A separate job has an exit code the deploy waits for.
  A migration inside `main` completes at some point during the rollout, so the new
  code is live against the old schema for a window nobody measured.

### The rules around it

- **Only the owner migrates a table.** When services share a database, exactly one of
  them lists a model in its `MigrateDB`. The others may hold a copy of the struct to
  read through, and say so in a comment on it; they never migrate it. Two services
  migrating one table is two schema owners on two deploy schedules, and the one that
  deploys second "fixes" the other's column.
- **Forward-only, additive across a rollout.** During a rolling deploy the old code runs
  against the new schema for as long as the rollout takes. Adding a column is safe.
  Removing one is two deploys: stop reading and writing it, ship; then drop it in step 3
  with `DROP COLUMN IF EXISTS`, ship. AutoMigrate never drops anything, which is the
  one part of its behaviour this rule relies on.
- **No reset in the binary.** A `ResetAndMigrateDB` that drops every table, compiled
  into the same binary that runs in production, is one mistyped environment variable
  away from deleting production. Local resets are a script against a local DSN, outside
  the service's code.
- **A big index is built `CONCURRENTLY`.** A plain `CREATE INDEX` on a large, hot table
  blocks writes for the whole build. `CREATE INDEX CONCURRENTLY IF NOT EXISTS` in step 3
  does not, and GORM's `Exec` runs outside a transaction, which `CONCURRENTLY`
  requires. If one fails it leaves an `INVALID` index; the next run's `IF NOT EXISTS`
  skips it, so step 3 drops invalid indexes by name before recreating them.

### Seeds and backfills

```go
// database/database_seed/countries.seed.go
package database_seed

import (
	"fmt"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// SeedCountries is idempotent by construction: an upsert on the natural key. Running it
// twice, or on a database that already has every row, changes nothing. A seed that
// checks "is the table empty" first is a seed that never updates a row once it exists,
// so the corrected spelling of a country name is shipped and never applied.
func SeedCountries(db *gorm.DB) error {
	return db.Clauses(clause.OnConflict{
		Columns:   []clause.Column{{Name: "iso_code"}},
		DoUpdates: clause.AssignmentColumns([]string{"name", "dial_code"}),
	}).CreateInBatches(countries, 200).Error
}

// RunAll is the single list, in order, called by cmd/migration after MigrateDB.
func RunAll(db *gorm.DB) error {
	steps := []struct {
		name string
		run  func(*gorm.DB) error
	}{
		{"countries", SeedCountries},
		{"subscription plans", SeedSubscriptionPlans},
		{"seat data backfill", BackfillSeatData},
	}
	for _, s := range steps {
		if err := s.run(db); err != nil {
			return fmt.Errorf("seed %s: %w", s.name, err)
		}
	}
	return nil
}
```

- **Every seed is an upsert on a natural key.** Reference data is code, and code that
  changes has to be re-appliable.
- **A backfill selects only the rows it has not done yet** (`WHERE new_col IS NULL`),
  in batches, each batch its own transaction, so it is safe to re-run after a partial
  failure and never holds a lock on the whole table.
- **A backfill that is finished is deleted** in a later release, once every
  environment has run it. Leaving it in `RunAll` forever is a scan per deploy that
  does nothing.

## Tenancy is a scope on every query

**A query missing its tenant predicate is not a bug. It is a data breach.** It ships
green, passes every test written by someone with one tenant in their fixture, and the
first report is from a customer reading another customer's rows.

So the predicate is not something each query remembers. It is one function:

```go
// internal/helpers/tenancy.helper.go
package helpers

import (
	"example.com/users-service/internal/contracts"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// TenantScope restricts a query to one parent user's rows. It has the signature of a
// GORM scope AND of a PaginatedQueryFunc, so the same call works in db.Scopes(...) and
// as the first modifier to ExecutePaginatedQuery.
//
// A zero or negative id is refused with db.AddError. GORM checks the statement's error
// before it builds SQL, so the query never runs: an unscoped query fails loudly as a
// 500 with a reference instead of quietly matching every tenant's rows. The zero is not
// hypothetical - it is what an unset struct field, a failed Atoi and a missing JWT claim
// all produce.
func TenantScope(parentUserID int) func(*gorm.DB) *gorm.DB {
	return func(db *gorm.DB) *gorm.DB {
		if parentUserID <= 0 {
			_ = db.AddError(contracts.ErrMissingTenantScope)
			return db
		}
		return db.Where(onCurrentTable("parent_user_id", parentUserID))
	}
}

// AccountScope narrows to one account inside the tenant, for tables whose rows belong
// to an account. It is TenantScope plus the account, never the account alone: an
// account id without its tenant is a scope a forged id can satisfy.
func AccountScope(parentUserID, ownerAccountID int) func(*gorm.DB) *gorm.DB {
	return func(db *gorm.DB) *gorm.DB {
		if ownerAccountID <= 0 {
			_ = db.AddError(contracts.ErrMissingTenantScope)
			return db
		}
		return TenantScope(parentUserID)(db).Where(onCurrentTable("owner_account_id", ownerAccountID))
	}
}

// onCurrentTable qualifies the column with the statement's own table, resolved when
// GORM builds the SQL, so a scoped query that joins another tenant-owned table is not
// an "ambiguous column" error. (Statement.Table is not usable here: GORM runs scopes
// before it parses the model, so at this point the table is usually still empty.)
func onCurrentTable(column string, value int) clause.Eq {
	return clause.Eq{Column: clause.Column{Table: clause.CurrentTable, Name: column}, Value: value}
}
```

Used:

```go
database.Db.Scopes(helpers.TenantScope(parentUserID)).First(&h, holidayID)            // a read by id
database.Db.Scopes(helpers.AccountScope(parentUserID, accountID)).Find(&campaigns)    // an account's rows
helpers.ExecutePaginatedQuery[model.UserHoliday](database.Db, p, helpers.TenantScope(parentUserID), ...)
```

Be honest about what it buys and what it does not:

- **It makes a missing tenant an error instead of a breach**, on every query that uses
  it, including the read by primary key that "obviously" does not need a scope. It
  does: an id is a guessable integer, and the scope is what turns another tenant's id
  into a 404.
- **It cannot force a query to use it.** A query that never calls `TenantScope`
  compiles. What it changes is that the omission is now visible: every query on a
  tenant-owned table either says `Scopes(helpers.TenantScope(` or does not, and a
  reviewer can grep for the ones that do not.
- **`Raw` and `Exec` bypass scopes entirely.** Raw SQL on a tenant-owned table writes
  `parent_user_id = ?` itself, and a reviewer reads that line specifically.
- **A join is scoped on both sides.** Scoping `deals` and joining `campaigns` by id
  alone returns another tenant's campaign name through the join if the two ids ever
  disagree. Join on the tenant column too.

## Locking: pick by contention shape

| Contention shape | Primitive | In GORM |
|---|---|---|
| One contested row, N writers, all must apply (a quota, a balance) | `SELECT ... FOR UPDATE` in the transaction | `tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&row, id)` |
| Many independent rows, N workers, each row once | `FOR UPDATE SKIP LOCKED` | `clause.Locking{Strength: "UPDATE", Options: "SKIP LOCKED"}` with a `Limit` |
| One job, N replicas, one should run | advisory lock | `references/background-work.md` |

The wrong choice does not error, it degrades into something that looks like a
different problem. `FOR UPDATE` without `SKIP LOCKED` on a work queue makes N workers
deliver the throughput of one, and the graph looks like a capacity problem, so someone
adds capacity and it does not move. `SKIP LOCKED` on a contested row makes the writers
that skip it silently do nothing: the update is lost, no error, no log.

## Checklist

A data-layer change is done when all of these are true. Any "no" is the bug you ship.

- The query is in a service (or a helper the service hands a handle to), never in a
  handler.
- It is inside `SafeDBQuery` or `SafeDBTransaction`, and the call site returns the
  error.
- Every query on a tenant-owned table uses `TenantScope` or `AccountScope`; every
  `Raw`/`Exec` on one writes the predicate itself.
- `gorm.ErrRecordNotFound` and `gorm.ErrDuplicatedKey` become the resource's
  sentinels; nothing above the service sees a GORM error type.
- Inside a transaction callback, every statement uses `tx`, and nothing talks to
  anything but this database.
- A write that can be retried is an upsert against a real unique index.
- `RowsAffected` is checked on every update and delete whose zero is a failure.
- The model has explicit `column:` tags, a `TableName()`, tenancy columns, and an index
  that leads with the tenant.
- The schema change is in `MigrateDB` (rename first, AutoMigrate, then idempotent SQL),
  and it is additive across a rollout.
- Nothing in `cmd/main.go` migrates, seeds or backfills.
