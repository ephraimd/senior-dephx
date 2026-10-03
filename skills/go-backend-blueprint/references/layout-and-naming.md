# Layout and naming

Where every file in the service lives, what it is called, and what the types inside it
are called. Read this first: every other reference names files and types from here and
does not restate them.

The spine says one folder per resource, models in one place, and composition in one
function. This is the tree that makes all three true.

## The tree

```
<service>/
├── cmd/
│   ├── main.go                     # the HTTP process: engine, middleware, serve, shutdown
│   ├── migration/
│   │   └── migrate.go              # the pre-deploy job: schema, then seeds. Nothing else migrates.
│   └── worker/
│       └── main.go                 # OPTIONAL: Pattern C worker binary, no HTTP
├── database/
│   ├── pgsql.go                    # LoadDatabase / CloseDatabase, the global Db
│   ├── db_migrate.go               # MigrateDB: renames, AutoMigrate, raw idempotent SQL
│   ├── database_seed/              # idempotent seeds and backfills, run by cmd/migration only
│   │   └── countries.seed.go
│   └── model/                      # GORM models ONLY. One file per table.
│       └── user_holiday.go
├── internal/
│   ├── config/
│   │   └── config.go               # Config struct, LoadConfig, GlobalConfig
│   ├── contracts/
│   │   ├── application.contracts.go  # environments, enums, shared constants
│   │   ├── <domain>.contracts.go   # cross-service enums and shared DTO shapes
│   │   └── errors.go               # contracts.Error and every sentinel
│   ├── helpers/
│   │   ├── http_response.go        # RespondOk, RespondCreated, RespondPaginated, RespondError, RespondServiceError
│   │   ├── binding.helper.go       # BindingError, PathID, RegisterJSONFieldNames
│   │   ├── pagination.go           # PaginationParams, ExecutePaginatedQuery, BuildPaginationMeta
│   │   ├── db.helper.go            # SafeDBQuery, SafeDBTransaction, IsNotFound
│   │   ├── tenancy.helper.go       # TenantScope, AccountScope
│   │   ├── osenv.helper.go         # GetOsEnvOrPanic, GetOsEnvOrDefault
│   │   └── ptr.go                  # StringPtr, IntPtr, BoolPtr
│   ├── middleware/
│   │   ├── recovery.go             # Recovery: panic -> 500 envelope + report
│   │   ├── access_log.go           # AccessLog: gin's line, secrets redacted
│   │   ├── cors.go                 # CORS, SecureHeaders
│   │   ├── user_jwt_auth.go        # RequireValidJWT, GetJWTUserFromContext
│   │   └── internal_services_auth.go # InternalServicesAuth
│   ├── resources/
│   │   └── holidays_resource/
│   │       ├── dto/
│   │       │   └── holidays.dto.go
│   │       ├── holidays.handler.go
│   │       ├── holidays.service.go
│   │       ├── holidays.helper.go
│   │       └── holidays.service_test.go
│   └── routes/
│       ├── routes.go               # SetupRouter: clients -> services -> handlers -> routes
│       └── swagger.go              # the swaggo docs route
├── pkg/
│   ├── logger/logger.go            # logger.Logger, logrus, JSON
│   ├── httpclient/client.go        # the one outbound HTTP wrapper
│   ├── concurrency/concurrency.go  # Run (bounded pool), Go (Pattern A)
│   ├── worker/ticker.go            # Ticker (Pattern B)
│   ├── queue/queue.go              # OPTIONAL: Pattern C, Redis
│   ├── activities_client/          # one typed client per peer service
│   │   ├── client.go
│   │   ├── activities_client.dto.go
│   │   └── activities_client.helper.go
│   └── crm/                        # adapter interface + one package per vendor (crm/crma, crm/crmb)
├── docs/                           # swag init output; generated, never hand-edited
├── go.mod
└── Dockerfile
```

Every folder in that tree answers one question, and the answer never moves:

| Question | Folder |
|---|---|
| What runs, and how does it start and stop? | `cmd/` |
| What does the database look like, and who changes it? | `database/` |
| What does this process read from its environment? | `internal/config/` |
| What words do all the layers share? | `internal/contracts/` |
| What does every resource do the same way? | `internal/helpers/` |
| What happens to every request before a handler sees it? | `internal/middleware/` |
| What does this service actually do? | `internal/resources/` |
| What is this service made of, and what URL reaches what? | `internal/routes/` |
| What would be the same in another service? | `pkg/` |

A file that cannot say which of those questions it answers is in the wrong place, or
is two files.

## The resource folder

**One folder per resource. Everything that changes when the resource changes lives in
it, except its model.** A reviewer opening a feature's diff should see one folder and
`database/model/`, not five top-level directories that each grew a file.

```
internal/resources/holidays_resource/
    dto/holidays.dto.go         the wire: what comes in, what goes out
    holidays.handler.go         parse, validate, delegate, respond
    holidays.service.go         every decision, every query, every transaction
    holidays.helper.go          model -> response mapping, private service helpers
    holidays.worker.go          OPTIONAL: a Pattern B ticker over a service method
    holidays.service_test.go    tests next to the code they test
```

Each file has one job and the job is in its name:

- **`.handler.go`** knows Gin. It reads the path, the query, the body and the
  credential, calls one service method, and writes one response. It never imports
  `database`.
- **`.service.go`** knows the business and the database. It never imports Gin. A
  service method is callable from a handler, a worker, a test and a migration seed
  with no HTTP anywhere, which is the entire reason it does not take a `*gin.Context`.
- **`.helper.go`** is the resource's private toolbox: `toHolidayResponseDTO`, a date
  parser, an unexported method on the service that three public methods share. It is
  not a second service. A helper that makes a decision a caller depends on belongs in
  the service, where the next reader will look for it.
- **`dto/`** is a subpackage so a peer's client, a test and the swag generator can
  import the wire types without importing the handler.

**Extend the resource that owns the feature before creating a new one.** OAuth for a
CRM integration lives in the CRM resource's service, not in a new `oauth_resource`,
because the two change together and a reviewer should see them together. A new
resource folder is for a genuinely new noun, not for a new verb on an old one.

**A resource reaches another resource through its service, handed in by
`SetupRouter`.** Never through its helper, never by importing its handler, never by
querying its tables directly from your service. A query against another resource's
table from your service is a second owner of that table, and the first owner's next
migration breaks code that is not in its folder.

## Package and import names

Folders are `snake_case`. Package names are the folder with the underscores removed,
because Go package names do not take underscores well and the folder name is what a
human greps for.

| Folder | Package | Import alias in `routes.go` |
|---|---|---|
| `internal/resources/holidays_resource` | `holidaysresource` | `holidaysresource` |
| `internal/resources/holidays_resource/dto` | `holidaysresource_dto` | `holidaysresource_dto` |
| `internal/middleware` | `middleware` | `middleware` |
| `pkg/activities_client` | `activities_client` | `activitiesclient` |

The DTO package keeps its underscore deliberately. `holidaysresource_dto.HolidayResponseDTO`
reads at the call site as "the holidays resource's wire type", and every DTO import in
the codebase looks the same, so nobody invents a fourth alias style.

## Type and constructor names

```go
// internal/resources/holidays_resource/holidays.service.go

// The concrete type is <Name>ServiceImpl. There is no HolidaysService interface,
// because there is exactly one implementation and there will only ever be one: an
// interface with one implementation forever is an indirection with no seam in it.
// The seams in this blueprint are where an implementation is genuinely replaceable -
// a vendor adapter, a peer client - and nowhere else.
type HolidaysServiceImpl struct {
	activitiesClient *activitiesclient.ActivitiesClient
}

// New<Name>Service returns the concrete pointer AND an error, even when nothing in it
// can fail today. Every handler and service constructor has the same shape, so
// SetupRouter handles every one of them the same way, and the day this constructor gains a
// dependency that can fail is not a signature change across every caller.
func NewHolidaysService(activitiesClient *activitiesclient.ActivitiesClient) (*HolidaysServiceImpl, error) {
	if activitiesClient == nil {
		return nil, errors.New("holidays service: activities client is required")
	}
	return &HolidaysServiceImpl{activitiesClient: activitiesClient}, nil
}
```

```go
// internal/resources/holidays_resource/holidays.handler.go

type HolidaysHandlerImpl struct {
	service *HolidaysServiceImpl // unexported: nothing outside the handler calls through it
}

func NewHolidaysHandler(service *HolidaysServiceImpl) (*HolidaysHandlerImpl, error) {
	if service == nil {
		return nil, errors.New("holidays handler: service is required")
	}
	return &HolidaysHandlerImpl{service: service}, nil
}
```

The rules those encode:

- **`<Name>HandlerImpl`, `<Name>ServiceImpl`, `<Name>Worker`.** The suffix tells a reader
  which layer a type belongs to without opening the file.
- **`New<Name><Layer>(deps...) (*<Name><Layer>Impl, error)`.** Dependencies are
  parameters, in the order `SetupRouter` constructs them. A constructor that reaches
  for a peer client through a package-level accessor has a dependency `SetupRouter`
  cannot see, and the dependency order in that function stops being the truth.
- **A nil dependency is a construction error, not a runtime one.** `SetupRouter`
  panics on it at boot, naming the resource. The alternative is a nil-pointer panic
  on the first request that reaches the one method that used it, which might be the
  billing path, at 3am.
- **The process-wide handles are the exceptions, and there are exactly three:**
  `database.Db`, `config.GlobalConfig`, `logger.Logger`. They are globals on purpose
  (see `references/composition-and-lifecycle.md` for what that buys and what it costs).
  Nothing else is. A fourth package-level `var` holding a client, a cache or a worker
  is a dependency that `SetupRouter` cannot see.

## The four DTO kinds

Every resource that accepts or returns data has these, named exactly like this.

```go
// internal/resources/holidays_resource/dto/holidays.dto.go
package holidaysresource_dto

import "example.com/users-service/internal/helpers"

// CreateHolidayDTO: value types, binding:"required" on what must be present. A value
// type is right here because "absent" and "zero" mean the same thing on a create:
// there is no previous value to leave alone.
type CreateHolidayDTO struct {
	HolidayDate string `json:"holiday_date" binding:"required" example:"2026-12-25"`
	Name        string `json:"name" binding:"max=120" example:"Christmas Day"`
}

// UpdateHolidayDTO: every field a pointer. nil means "do not touch this column";
// a non-nil zero means "set it to zero". Without the pointer the two are the same
// bytes, and a client that sends {"is_active": false} to switch a holiday off is
// indistinguishable from one that left the field out - so one of them silently
// gets the other's behaviour.
type UpdateHolidayDTO struct {
	Name     *string `json:"name,omitempty" binding:"omitempty,max=120"`
	IsActive *bool   `json:"is_active,omitempty"`
}

// HolidayResponseDTO: json tags only, built from the model by toHolidayResponseDTO in
// holidays.helper.go. It lists what the client may see, field by field.
type HolidayResponseDTO struct {
	ID          int    `json:"id"`
	HolidayDate string `json:"holiday_date"`
	Name        string `json:"name"`
	IsActive    bool   `json:"is_active"`
}

// HolidayListQueryDTO: form tags, bound with ShouldBindQuery. It embeds the one
// PaginationParams so page and limit are spelled the same on every list endpoint.
type HolidayListQueryDTO struct {
	helpers.PaginationParams
	Year     *int  `form:"year" binding:"omitempty,min=2000,max=2100"`
	IsActive *bool `form:"is_active"`
}
```

**Never a model on the wire, in either direction.** `model.UserHoliday` in a response
publishes every column anyone adds to that struct later, automatically, forever,
including the one someone names `internal_notes`. `model.UserHoliday` as a request body
lets a client set `id`, `created_at`, `parent_user_id` and `deleted_at`, because GORM
will write whatever the struct holds. The mapping function is a few lines of typing,
and those lines are the boundary.

**A user-facing DTO has no tenant field.** No `parent_user_id`, no `owner_account_id`,
no `user_id`, no `role`. Identity comes from the credential
(`references/http-layer.md`), and a field that can carry it is a field a client can
forge. An internal, service-to-service DTO may carry tenant ids, because its caller
authenticated with the service secret and derived them from a credential itself
(`references/inter-service.md`).

**No `map[string]interface{}` in a DTO.** A map is a contract no reviewer can read and
no compiler can check. The one exception is a BFF's aggregate response, and it is
narrow; `references/inter-service.md` draws its edge.

## Where does this go?

| Code | Goes in |
|---|---|
| Reading a path param, binding a body, choosing a status | the resource's handler |
| A rule, a query, a transaction, a side effect | the resource's service |
| Model -> response DTO, a parser only this resource uses | the resource's helper |
| A GORM struct | `database/model/<table>.go` |
| A schema change | `database/db_migrate.go`, run by `cmd/migration` |
| Reference data or a backfill | `database/database_seed/`, run by `cmd/migration` |
| An enum, a status string, a provider name | `internal/contracts/` |
| A failure a client can act on | a sentinel in `internal/contracts/errors.go` |
| A response shape, the error map, pagination, the DB panic guard | `internal/helpers/` |
| Something every request passes through | `internal/middleware/` |
| Which object depends on which, which URL reaches which handler | `internal/routes/routes.go` |
| A call to another service you own | `pkg/<service>_client/` |
| A call to a third party | `pkg/<vendor>/`, behind an adapter |
| Something the next service will need byte for byte | `pkg/` |

Two of those are worth defending:

- **Models live in `database/model/`, not in the resource folder.** This departs from
  pure feature-folders on purpose. A model is the table, and a table outlives the
  resource that created it: three resources read `users`, a migration registers every
  model in one list, and a peer service that shares the database copies the struct.
  Putting the model in one resource makes the other two reach into it, which is
  worse than all of them reaching into `database/model/`.
- **Constants live in `internal/contracts/`, not beside the code that uses them
  first.** A status string written in a service is a literal; the same string written
  in a worker, a seed and a peer's client is four literals, and one of them gets the
  case wrong. `contracts.HolidayStatusActive` is the only spelling.

## File names

All `snake_case`, with the role as a dot-suffix, so a directory listing groups by
resource and reads by role:

| Kind | Pattern | Example |
|---|---|---|
| Handler | `<name>.handler.go` | `holidays.handler.go` |
| Service | `<name>.service.go` | `holidays.service.go` |
| Resource helper | `<name>.helper.go` | `holidays.helper.go` |
| Worker | `<name>.worker.go` | `csv_import.worker.go` |
| DTOs | `dto/<name>.dto.go` | `dto/holidays.dto.go` |
| Model | `<table_singular>.go` | `user_holiday.go` |
| Seed | `<name>.seed.go` | `countries.seed.go` |
| Shared helper | `<name>.helper.go` or a plain noun | `db.helper.go`, `pagination.go` |
| Peer client | `client.go`, `<svc>_client.dto.go`, `<svc>_client.helper.go` | `pkg/activities_client/client.go` |

One spelling. A service that has `httpResponse.go` in one place and `http_response.go`
in another has two conventions, and the third person picks a third.

## `pkg/` is for what another service would copy

`pkg/` holds code that would be the same, byte for byte, in the next service: the
logger, the HTTP client wrapper, the bounded pool, the ticker, the typed client for a
peer, the adapter for a vendor.

- **`pkg/` never imports `internal/`, with one exception: `internal/contracts`.** A
  peer client returns contract types and sentinels, so it needs them. It never needs a
  helper, a resource or a model. A `pkg/` package that imports a resource is a
  resource that has been filed in the wrong folder.
- **Extract to `pkg/` at the second service, not the first.** One user is a guess
  about the shape. The second user is the evidence. When it moves, it moves whole, and
  the first service switches to it in the same change.

## Refactor order

Bringing an existing service to this layout, one landable commit at a time. Behaviour
is frozen throughout; each step is revertible on its own.

1. **Create the empty skeleton**: `internal/contracts/errors.go`, the helpers, the
   middleware files. Nothing calls them yet. Green.
2. **Move models into `database/model/`**, one table per commit, fixing imports. No
   column changes.
3. **One resource at a time**, into `internal/resources/<name>_resource/` with its
   four files and `dto/`. Its routes move into a `setup<Name>Routes` in `routes.go`
   in the same commit, so the URL table never points at two places.
4. **Rename to `Impl` and the `(*Impl, error)` constructor shape** for that resource
   in the same commit as its move, so no resource is ever half-renamed.
5. **Adopt the error contract per resource** (`references/http-layer.md`): sentinels
   first, then `RespondServiceError` at every call site in that handler.

The resources nobody has touched yet stay in their old shape, and say so in the PR.
A resource left behind on purpose is a boundary; one left behind silently reads as an
abandoned job.
