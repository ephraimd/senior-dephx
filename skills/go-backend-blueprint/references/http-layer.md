# The HTTP layer

The edge. What every request passes through, what a handler is allowed to do, the one
shape every response wears on the way out, and the one function that turns a failure
into a status code.

The spine says layers do only their job, there is one response envelope, every error
reaches the wire through one helper, and every list paginates through one executor.
This is the code that makes those true.

## Routing is Gin groups, and auth belongs to the group

Routes are registered in `internal/routes/routes.go`, one `setup<Name>Routes` function
per resource (`references/composition-and-lifecycle.md` shows the whole function).
Two rules carry the weight:

- **Auth is a property of the group, never of a route.** `v1.Group("",
  middleware.InternalServicesAuth())` is one decision about every route under it.
  `group.POST("/x", middleware.InternalServicesAuth(), h.X)` repeated per route is a
  list somebody appends to, and the route they forget is public forever with nothing
  to notice it.
- **A route's audience decides its group, and its group decides where identity comes
  from.** User-facing routes live under `RequireValidJWT` and read identity from the
  token. Service-to-service routes live under `InternalServicesAuth` and take tenant
  ids in the path. A route under neither is public, and a public route is a decision
  somebody made out loud in the PR, not a default.

```go
// The three audiences, as groups. Nothing is registered on v1 directly except the
// docs route, so "which group is this under" always has an answer.
internal := v1.Group("", middleware.InternalServicesAuth())
user := v1.Group("", middleware.RequireValidJWT())
public := v1.Group("/public") // the prefix says it, so a reviewer cannot miss it
```

## Middleware order is not a preference

Global middleware, outermost first: **Recovery, AccessLog, CORS, SecureHeaders.** Auth
is innermost, on the group. Each position is paid for by a specific failure.

- **Recovery outermost.** An unrecovered panic in a handler kills the process, along
  with every unrelated request in flight and every worker mid-write. Anything outside
  recovery is code whose panic is an outage.
- **AccessLog above auth.** Put logging inside auth and every rejected request is
  invisible: a credential-stuffing run leaves no trace in the access log, and the
  first evidence is the account that gets taken over.
- **CORS above auth.** A browser's preflight `OPTIONS` carries no credential. Auth
  above CORS answers every preflight with a 401, and the browser reports it as a CORS
  failure, so the frontend team debugs the wrong service for an afternoon.
- **Auth innermost.** Nothing sits between it and the handler, so nothing can drop or
  overwrite the identity it put in the context.

```go
// internal/middleware/recovery.go
package middleware

import (
	"net/http"
	"runtime/debug"

	"example.com/users-service/internal/helpers"
	"example.com/users-service/pkg/logger"

	"github.com/gin-gonic/gin"
)

// Recovery replaces gin.Recovery. Same job - a panic becomes a 500 instead of a dead
// process - but the 500 goes through the envelope, carries a reference, and the stack
// goes to the log under that reference instead of to stderr in gin's own format.
func Recovery() gin.HandlerFunc {
	return gin.CustomRecovery(func(c *gin.Context, recovered any) {
		ref := helpers.NewErrorRef()
		logger.Logger.WithFields(map[string]any{
			"reference": ref,
			"method":    c.Request.Method,
			"path":      c.FullPath(), // the route pattern, not the raw URL with its query
			"panic":     recovered,
			"stack":     string(debug.Stack()),
		}).Error("handler panicked")
		c.AbortWithStatusJSON(http.StatusInternalServerError, helpers.GenericErrorBody(ref))
	})
}
```

```go
// internal/middleware/access_log.go

// sensitiveQueryParams are never written to the access log in plaintext. gin's default
// formatter logs the raw path with its query string, and a secret in a query string is
// a secret in every log aggregator, every backup of it, and every screenshot of a
// dashboard someone pastes into a chat.
var sensitiveQueryParams = map[string]struct{}{
	"secret": {}, "token": {}, "api_token": {}, "password": {}, "key": {}, "apikey": {},
}

func AccessLog() gin.HandlerFunc {
	return gin.LoggerWithConfig(gin.LoggerConfig{
		Formatter: redactingFormatter, // gin's line format, path rebuilt with values redacted
		SkipPaths: []string{"/healthz"},
	})
}
```

The redacting formatter mirrors `gin.defaultLogFormatter` field for field and builds
the path from `param.Request.URL` with each sensitive value replaced by `REDACTED`. It
cannot use `param.Path`: gin precomputes that from the raw, unredacted query.

`SkipPaths` drops the probe. A probe every two seconds is 43,200 lines a day that
describe nothing and bury the line you were looking for.

`CORS` reads its allowed origins from `Config` (exact matches plus `https://*.domain`
suffix patterns, with a non-empty subdomain required between them), answers `OPTIONS`
with 204, and allows `*` only when `Env` is local. `SecureHeaders` sets
`X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff` and a `default-src 'self'`
CSP on every response. Neither has an opinion worth a page.

## The handler's four moves

**Parse. Validate. Delegate. Respond.** In that order, once each, and nothing else.

```go
// internal/resources/holidays_resource/holidays.handler.go
package holidaysresource

import (
	"example.com/users-service/internal/contracts"
	"example.com/users-service/internal/helpers"
	"example.com/users-service/internal/middleware"
	holidaysresource_dto "example.com/users-service/internal/resources/holidays_resource/dto"

	"github.com/gin-gonic/gin"
)

// AddHoliday godoc
// @Summary     Mark a date as a holiday for a user
// @Tags        holidays
// @Accept      json
// @Produce     json
// @Param       user_id path int true "Parent user ID"
// @Param       body body holidaysresource_dto.CreateHolidayDTO true "Holiday"
// @Success     201 {object} swagger.HolidayEnvelope
// @Failure     400 {object} swagger.ErrorEnvelope
// @Failure     409 {object} swagger.ErrorEnvelope
// @Security    InternalSecret
// @Router      /holidays/user/{user_id} [post]
func (h *HolidaysHandlerImpl) AddHoliday(c *gin.Context) {
	// parse: the path
	parentUserID, err := helpers.PathID(c, "user_id")
	if err != nil {
		c.JSON(helpers.RespondServiceError(err))
		return
	}

	// parse + validate shape: the body
	var input holidaysresource_dto.CreateHolidayDTO
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(helpers.RespondServiceError(helpers.BindingError(err)))
		return
	}

	// delegate
	holiday, err := h.service.AddHoliday(parentUserID, input)
	if err != nil {
		c.JSON(helpers.RespondServiceError(err))
		return
	}

	// respond
	c.JSON(helpers.RespondCreated("holiday added", &gin.H{"holiday": toHolidayResponseDTO(holiday)}))
}

// ListMyHolidays is the user-facing twin: the same service method, the tenant taken
// from the token instead of the path.
func (h *HolidaysHandlerImpl) ListMyHolidays(c *gin.Context) {
	id, ok := middleware.IdentityFrom(c)
	if !ok {
		// Unreachable while this route is mounted under RequireValidJWT. It is here
		// because "unreachable" is a claim about the wiring, and the day someone mounts
		// this handler on the public group, a 401 is the failure you want - not a zero
		// tenant id reading somebody else's rows.
		c.JSON(helpers.RespondServiceError(contracts.ErrUnauthenticated))
		return
	}

	var query holidaysresource_dto.HolidayListQueryDTO
	if err := c.ShouldBindQuery(&query); err != nil {
		c.JSON(helpers.RespondServiceError(helpers.BindingError(err)))
		return
	}

	// The token's user_id IS the parent user, the tenant. owner_account_id, where a
	// table has one, is id.AccountID.
	result, err := h.service.ListHolidays(id.UserID, query)
	if err != nil {
		c.JSON(helpers.RespondServiceError(err))
		return
	}
	c.JSON(helpers.RespondPaginated("holidays retrieved", toHolidayResponseDTOs(result.Items),
		result.Page, result.Limit, int(result.TotalCount)))
}
```

Every `if` above is an early return from a failed parse or a failed call. That is the
whole shape. Notice what is not there: no `err.Error()`, no status code chosen by the
handler, no `if errors.Is(...)` ladder. The handler does not know which failures exist,
which is why adding one never edits a handler.

### No branch in a handler may change an outcome

The line is not "no `if` statements". It is that **a valid request has exactly one path
through the handler.**

```go
// ✘ A business rule, living in one entry point.
func (h *HolidaysHandlerImpl) AddHoliday(c *gin.Context) {
	...
	if config.GlobalConfig.Env == "prod" && input.HolidayDate < time.Now().Format("2006-01-02") {
		c.JSON(helpers.RespondError("cannot add a holiday in the past", nil, 400))
		return
	}
	holiday, err := h.service.AddHoliday(parentUserID, input)
	...
}
```

The CSV importer adds holidays. The admin backfill adds holidays. The worker that copies
a team's calendar adds holidays. None of them go through this function, so three of
the four paths never had the rule. No test fails, because the test for the rule is a
handler test and the handler still passes it.

**Validate means shape, not truth.** `binding:"required"` is shape: a fact about the
JSON. "Not in the past" is a rule: it depends on the clock and it must hold for the
importer too. The test is whether the answer can change while the request stays
byte-identical. If it can, it belongs in the service, and the service returns
`contracts.WithDetail(contracts.ErrHolidayInPast, "%s has already passed", d)`.

### Binding errors are translated, never echoed

```go
// ✘ The fleet's most common line, and a leak.
if err := c.ShouldBindJSON(&input); err != nil {
	c.JSON(helpers.RespondError("Invalid payload", &gin.H{"error": err.Error()}, 400))
	return
}
```

`err.Error()` from the validator reads `Key: 'CreateHolidayDTO.HolidayDate' Error:Field
validation for 'HolidayDate' failed on the 'required' tag`. That publishes your Go type
names, and it is useless to the user, who typed into a field labelled "Date". And when
the message is replaced by a fixed "invalid payload" instead, the user who sent an
8-character password to an endpoint that wants 12 is told nothing at all, and cannot
fix it.

`BindingError` gives them the field and the reason, in the wire's vocabulary:

```go
// internal/helpers/binding.helper.go
package helpers

import (
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strconv"
	"strings"

	"example.com/users-service/internal/contracts"

	"github.com/gin-gonic/gin"
	"github.com/gin-gonic/gin/binding"
	"github.com/go-playground/validator/v10"
)

// RegisterJSONFieldNames makes the validator report `holiday_date`, not
// `HolidayDate`. Called once from main, before the router serves.
func RegisterJSONFieldNames() {
	v, ok := binding.Validator.Engine().(*validator.Validate)
	if !ok {
		return
	}
	v.RegisterTagNameFunc(func(f reflect.StructField) string {
		for _, tag := range []string{"json", "form"} {
			name := strings.SplitN(f.Tag.Get(tag), ",", 2)[0]
			if name != "" && name != "-" {
				return name
			}
		}
		return f.Name
	})
}

// BindingError turns whatever ShouldBind* returned into a contracts error that
// RespondServiceError renders as a 400 with per-field reasons. It reports every
// failing field at once: returning the first one turns a six-field form into six
// round trips.
func BindingError(err error) error {
	var verrs validator.ValidationErrors
	if errors.As(err, &verrs) {
		fields := make(map[string]string, len(verrs))
		for _, fe := range verrs {
			fields[fe.Field()] = describe(fe)
		}
		return contracts.InvalidFields(fields)
	}

	var typeErr *json.UnmarshalTypeError
	if errors.As(err, &typeErr) {
		return contracts.InvalidFields(map[string]string{
			typeErr.Field: "must be a " + typeErr.Type.Kind().String(),
		})
	}

	// Syntax errors, empty bodies, two documents in one body. The decoder's own text
	// names byte offsets and Go types; the client gets a field it can act on.
	return contracts.InvalidFields(map[string]string{"body": "must be a single valid JSON object"})
}

func describe(fe validator.FieldError) string {
	switch fe.Tag() {
	case "required":
		return "is required"
	case "min":
		return "must be at least " + fe.Param()
	case "max":
		return "must be at most " + fe.Param()
	case "oneof":
		return "must be one of: " + fe.Param()
	case "email":
		return "must be a valid email address"
	default:
		return fmt.Sprintf("failed the %q check", fe.Tag())
	}
}

// PathID reads a positive integer path parameter, or returns the 400 that says which
// one was wrong. strconv in every handler is the same five lines written forty times,
// and one of the forty forgets the `<= 0` check.
func PathID(c *gin.Context, name string) (int, error) {
	n, err := strconv.Atoi(c.Param(name))
	if err != nil || n <= 0 {
		return 0, contracts.InvalidFields(map[string]string{name: "must be a positive integer"})
	}
	return n, nil
}
```

## The single envelope

**Every response goes through it.** Success, failure, probe, the 404 for an unknown
route, the 401 from middleware, the 500 from a panic. One handler writing a bare
`gin.H{"error": ...}` means every consumer needs two parsers, and the second one is the
one that never gets tested, because it only runs on the error path nobody triggers on
purpose.

The shape is `{message, data}`:

```json
{ "message": "holiday added", "data": { "holiday": { "id": 41, "holiday_date": "2026-12-25", "name": "Christmas Day", "is_active": true } } }
```

```json
{ "message": "holidays retrieved",
  "data": [ { "id": 41, "holiday_date": "2026-12-25", "name": "Christmas Day", "is_active": true } ],
  "pagination": { "current_page": 1, "per_page": 10, "total_count": 1, "total_pages": 1,
                  "has_next_page": false, "has_prev_page": false } }
```

```json
{ "message": "the request is not valid", "data": { "fields": { "holiday_date": "is required" } } }
```

```json
{ "message": "An unexpected error occurred. Please try again or contact support.", "reference": "9f3c1a2b" }
```

- **A single resource is an object keyed by its name**: `data.holiday`, `data.profile`.
  The key is what lets a response grow a second top-level field (`data.a2p_status`
  beside `data.profile`) without breaking any client.
- **A list is `data` itself, an array, with `pagination` beside it.** Always an array,
  never `null`: a nil slice marshals to `null`, and `null` where a client's type says
  array is a crash in every strictly-typed client, on the empty-result path nobody
  demos. Response slices are built with `make([]T, 0, n)`.
- **What goes inside `data` is a typed DTO.** `gin.H` is the envelope's container, not
  a payload type: `&gin.H{"holiday": dto}` is fine, `&gin.H{"holiday": gin.H{"id": ...}}`
  is a contract nobody can read.

```go
// internal/helpers/http_response.go
package helpers

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/http"

	"example.com/users-service/internal/contracts"
	"example.com/users-service/pkg/logger"

	"github.com/gin-gonic/gin"
)

const genericClientError = "An unexpected error occurred. Please try again or contact support."

func RespondOk(message string, data *gin.H) (int, gin.H) {
	return http.StatusOK, gin.H{"message": message, "data": data}
}

func RespondCreated(message string, data *gin.H) (int, gin.H) {
	return http.StatusCreated, gin.H{"message": message, "data": data}
}

// RespondPaginated is the only way a list leaves this service. It exists so that no
// handler ever assembles the pagination block by hand: two handlers computing
// total_pages is two rounding rules, and the client's "next" button breaks on
// whichever one got it wrong.
func RespondPaginated(message string, data any, page, limit, totalCount int) (int, gin.H) {
	return http.StatusOK, gin.H{
		"message":    message,
		"data":       data,
		"pagination": BuildPaginationMeta(page, limit, totalCount),
	}
}

// RespondError writes a refusal whose message is a LITERAL the caller wrote: the 401
// in an auth middleware, the 404 for an unknown route. It never receives err.Error().
// An error value reaches the wire through RespondServiceError, and only through it.
func RespondError(message string, data *gin.H, code int) (int, gin.H) {
	body := gin.H{"message": message}
	if data != nil {
		body["data"] = data
	}
	return code, body
}

// RespondServiceError is the ONLY place in this service where an error becomes a
// status code and a client message. See "One function maps an error to a response".
func RespondServiceError(err error) (int, gin.H) {
	var ce *contracts.Error
	if errors.As(err, &ce) {
		status := statusForKind(ce.Kind)
		body := gin.H{"message": ce.Message}
		if len(ce.Fields) > 0 {
			body["data"] = gin.H{"fields": ce.Fields}
		}
		// The full chain - every %w context a layer added - goes to the log. The client
		// got ce.Message, which a human wrote for them.
		if status >= http.StatusInternalServerError {
			logger.Logger.WithError(err).Warn("request refused: dependency unavailable")
		} else {
			logger.Logger.WithError(err).Info("request refused")
		}
		return status, body
	}

	// Unclassified: something this service never declared a sentinel for. The client
	// gets a fixed sentence and a reference; the cause goes to the log under the same
	// reference, so support can find it from a screenshot.
	ref := NewErrorRef()
	logger.Logger.WithError(err).WithField("reference", ref).Error("unclassified error")
	return http.StatusInternalServerError, GenericErrorBody(ref)
}

func GenericErrorBody(ref string) gin.H {
	return gin.H{"message": genericClientError, "reference": ref}
}

func statusForKind(k contracts.ErrorKind) int {
	switch k {
	case contracts.KindInvalid:
		return http.StatusBadRequest
	case contracts.KindUnauthenticated:
		return http.StatusUnauthorized
	case contracts.KindForbidden:
		return http.StatusForbidden
	case contracts.KindNotFound:
		return http.StatusNotFound
	case contracts.KindConflict:
		return http.StatusConflict
	case contracts.KindUnavailable:
		return http.StatusServiceUnavailable
	default:
		return http.StatusInternalServerError
	}
}

// NewErrorRef is correlation, not a secret: eight hex characters a user can read
// aloud to support.
func NewErrorRef() string {
	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {
		return "unknown"
	}
	return hex.EncodeToString(b)
}
```

## One function maps an error to a response

Services return **sentinel errors declared in `internal/contracts/errors.go`**. Each
sentinel carries its kind (which decides the status) and its message (which a human
wrote for the client). `RespondServiceError` maps the kind to a status in one switch.
Nothing else in the service chooses a status for an error, and nothing else decides
what a client may read.

```go
// internal/contracts/errors.go
package contracts

import (
	"errors"
	"fmt"
	"sort"
	"strings"
)

// ErrorKind is what a failure IS, from the client's side. It decides the status code;
// helpers.statusForKind is the only place that knows the mapping.
type ErrorKind int

const (
	KindInvalid ErrorKind = iota + 1
	KindUnauthenticated
	KindForbidden
	KindNotFound
	KindConflict
	KindUnavailable
)

// Error is a failure this service has a sentence for. Message is client-safe BY
// CONSTRUCTION: it is a literal somebody wrote in this file, or a detail somebody
// formatted deliberately with WithDetail. It is never a driver's text, a peer's stack,
// or err.Error() of anything.
type Error struct {
	Kind    ErrorKind
	Message string
	Fields  map[string]string // per-field reasons, for KindInvalid
	parent  *Error            // the sentinel this was derived from, for errors.Is
}

func (e *Error) Error() string { return e.Message }

// Unwrap is what makes errors.Is(err, ErrSeatsExhausted) true for a WithDetail error
// built from it. The nil check is not decoration: returning a nil *Error as an error
// interface is a non-nil error, and errors.Is would walk into it.
func (e *Error) Unwrap() error {
	if e.parent == nil {
		return nil
	}
	return e.parent
}

func Invalid(msg string) *Error         { return &Error{Kind: KindInvalid, Message: msg} }
func Unauthenticated(msg string) *Error { return &Error{Kind: KindUnauthenticated, Message: msg} }
func Forbidden(msg string) *Error       { return &Error{Kind: KindForbidden, Message: msg} }
func NotFound(msg string) *Error        { return &Error{Kind: KindNotFound, Message: msg} }
func Conflict(msg string) *Error        { return &Error{Kind: KindConflict, Message: msg} }
func Unavailable(msg string) *Error     { return &Error{Kind: KindUnavailable, Message: msg} }

// WithDetail derives an error from a sentinel with a detail the user can act on: the
// number of seats the plan has, the length the password needs. errors.Is still matches
// the sentinel, so callers that branch on it are unaffected.
func WithDetail(sentinel *Error, format string, args ...any) *Error {
	return &Error{
		Kind:    sentinel.Kind,
		Message: sentinel.Message + ": " + fmt.Sprintf(format, args...),
		parent:  sentinel,
	}
}

// InvalidFields is a validation failure with a reason per field.
func InvalidFields(fields map[string]string) *Error {
	keys := make([]string, 0, len(fields))
	for k := range fields {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, k+" "+fields[k])
	}
	return &Error{
		Kind:    KindInvalid,
		Message: ErrInvalidInput.Message + ": " + strings.Join(parts, "; "),
		Fields:  fields,
		parent:  ErrInvalidInput,
	}
}

// Cross-cutting sentinels.
var (
	ErrInvalidInput    = Invalid("the request is not valid")
	ErrUnauthenticated = Unauthenticated("authentication required")
	ErrForbidden       = Forbidden("you do not have access to this")
	ErrUnavailable     = Unavailable("this is temporarily unavailable, please try again")

	// Internal, deliberately NOT a *Error: it has no client sentence because a client
	// can do nothing about it. It reaches the wire as the generic 500 with a reference.
	ErrMissingTenantScope = errors.New("query has no tenant scope")

	// Marks a failure that will fail identically on every retry: a job wraps it and
	// the queue dead-letters at once (references/background-work.md); a webhook
	// handler wraps it and answers 200 (references/inter-service.md).
	ErrNonRetryable = errors.New("non-retryable")
)

// One block per resource, named Err<Resource><What>, written for the person who will
// read it in the UI.
var (
	ErrHolidayNotFound      = NotFound("holiday not found")
	ErrHolidayAlreadyExists = Conflict("a holiday already exists on that date")
	ErrHolidayInPast        = Invalid("that holiday has already passed")

	ErrSeatsExhausted = Conflict("your plan does not include additional user seats")
)
```

Used in a service:

```go
// The detail is formatted on purpose, at the call site that knows the number.
if used >= plan.Seats {
	return contracts.WithDetail(contracts.ErrSeatsExhausted,
		"it includes %d and all are in use, upgrade your plan to add more users", plan.Seats)
}

// Context for the LOG is added with %w, freely. The client still reads the
// sentinel's message, because RespondServiceError reads ce.Message and never
// err.Error() of the chain.
if helpers.IsNotFound(err) {
	return nil, fmt.Errorf("remove holiday %d for user %d: %w", holidayID, parentUserID, contracts.ErrHolidayNotFound)
}
```

Three properties make this hold:

- **`errors.As` and `errors.Is` see through `%w`**, so any layer is free to wrap with
  context and the mapping still finds the sentinel.
- **The message is written for the client, once, in one file.** A reviewer reading
  `errors.go` is reading every sentence this service can say to a user when something
  goes wrong. That is the review that catches "pq: duplicate key", and it is a review
  of one file.
- **The mapping is total.** Anything that is not a `*contracts.Error` is a 500 with a
  generic sentence and a reference. A new failure mode that nobody classified is safe
  by default, and loud in the log.

### What it replaces

```go
// ✘ Three ways the fleet's handlers decide what a client reads.
c.JSON(helpers.RespondError(err.Error(), nil, http.StatusBadRequest))

c.JSON(helpers.RespondError("failed to create", &gin.H{"error": err.Error()}, 500))

// and, in RespondError itself, a scrubber:
for _, sig := range []string{"pq:", "gorm", "duplicate key", "violates", ...} {
	if strings.Contains(strings.ToLower(message), sig) { message = genericClientError }
}
```

- **A blanket 400 with `err.Error()`** makes a dropped database connection the
  client's fault. The client does not retry a 400, so a transient failure becomes a
  permanent one, and the text it shows the user is the driver's.
- **`"error": err.Error()` in `data`** publishes the whole wrap chain: the internal
  operation names, the ids, the peer's raw response body.
- **Scrubbing by string-matching is a denylist against text nobody controls.** It is
  right until the day a driver phrases a constraint violation in a way the list did
  not anticipate, and on that day it leaks, silently, with every test green. It also
  fails in the other direction: a legitimate business message that happens to contain
  "not active" or "already exists" is waved through even when it came from somewhere
  it should not have. A message is safe because somebody wrote it for a client, not
  because it failed to match a list.

## Pagination goes through one executor

`ExecutePaginatedQuery` is how a list leaves this service. Not "for the big tables":
for all of them. "This table is small" is a statement about today and about your own
tenants, and the unbounded query is a full scan waiting for the tenant who makes it
fatal.

```go
// internal/helpers/pagination.go
package helpers

import (
	"fmt"
	"math"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const (
	DefaultPage  = 1
	DefaultLimit = 10
	MaxLimit     = 100 // the hard ceiling; no parameter raises it
)

type PaginationParams struct {
	Page  int `form:"page,omitempty" json:"page" example:"1"`
	Limit int `form:"limit,omitempty" json:"limit" example:"10"`
}

type PaginationMeta struct {
	CurrentPage  int  `json:"current_page"`
	PerPage      int  `json:"per_page"`
	TotalCount   int  `json:"total_count"`
	TotalPages   int  `json:"total_pages"`
	HasNextPage  bool `json:"has_next_page"`
	HasPrevPage  bool `json:"has_prev_page"`
	NextPage     *int `json:"next_page,omitempty"`
	PreviousPage *int `json:"previous_page,omitempty"`
}

// PaginatedResult is generic over the row type, so the caller gets []model.UserHoliday
// back and not an interface{} it has to assert.
type PaginatedResult[T any] struct {
	Items      []T
	TotalCount int64
	Page       int
	Limit      int
}

// PaginatedQueryFunc is a GORM scope by another name: the same signature, so
// TenantScope, a filter and an Order clause all compose the same way.
type PaginatedQueryFunc = func(db *gorm.DB) *gorm.DB

// NormalizePagination clamps, it does not reject. A client asking for 10,000 gets 100
// and a working list. What it must never get is 10,000: an unbounded limit is a full
// read any client can trigger on any endpoint.
func NormalizePagination(p *PaginationParams) {
	if p.Page < 1 {
		p.Page = DefaultPage
	}
	if p.Limit < 1 {
		p.Limit = DefaultLimit
	}
	if p.Limit > MaxLimit {
		p.Limit = MaxLimit
	}
}

func ExtractPaginationFromContext(c *gin.Context) (PaginationParams, error) {
	var p PaginationParams
	if err := c.ShouldBindQuery(&p); err != nil {
		return PaginationParams{}, BindingError(err)
	}
	NormalizePagination(&p)
	return p, nil
}

func ExecutePaginatedQuery[T any](
	db *gorm.DB,
	params PaginationParams,
	modifiers ...PaginatedQueryFunc,
) (PaginatedResult[T], error) {
	NormalizePagination(&params)

	// Modifiers are applied now, in order, not deferred through db.Scopes: the count
	// below runs on a copy of this statement, and it must be the same scoped,
	// filtered statement the list runs on.
	var zero T
	query := db.Model(&zero)
	for _, modify := range modifiers {
		query = modify(query)
	}

	var total int64
	// A fresh session so the count does not inherit the limit and offset below. GORM
	// drops ORDER BY from a count on its own.
	if err := query.Session(&gorm.Session{}).Count(&total).Error; err != nil {
		return PaginatedResult[T]{}, fmt.Errorf("count: %w", err)
	}

	items := make([]T, 0, params.Limit)
	err := query.
		// The tiebreak, appended after every caller-supplied order, always. Without a
		// unique last sort key, forty rows sharing a created_at have no defined order,
		// the database returns them differently per execution, and page 2 repeats rows
		// from page 1 while skipping others entirely. Nothing errors: the count says 40
		// and the client assembles 38. The primary key is unique by construction and
		// indexed by definition.
		Order(clause.OrderByColumn{Column: clause.Column{Table: clause.CurrentTable, Name: clause.PrimaryKey}}).
		Offset((params.Page - 1) * params.Limit).
		Limit(params.Limit).
		Find(&items).Error
	if err != nil {
		return PaginatedResult[T]{}, fmt.Errorf("list: %w", err)
	}

	return PaginatedResult[T]{Items: items, TotalCount: total, Page: params.Page, Limit: params.Limit}, nil
}

func BuildPaginationMeta(page, limit, totalCount int) PaginationMeta {
	totalPages := int(math.Ceil(float64(totalCount) / float64(limit)))
	meta := PaginationMeta{
		CurrentPage: page,
		PerPage:     limit,
		TotalCount:  totalCount,
		TotalPages:  totalPages,
		HasNextPage: page < totalPages,
		HasPrevPage: page > 1,
	}
	if meta.HasNextPage {
		next := page + 1
		meta.NextPage = &next
	}
	if meta.HasPrevPage {
		prev := page - 1
		meta.PreviousPage = &prev
	}
	return meta
}
```

Used, in the service (the tenant scope is `references/data-layer.md`'s):

```go
func (s *HolidaysServiceImpl) ListHolidays(
	parentUserID int,
	query holidaysresource_dto.HolidayListQueryDTO,
) (helpers.PaginatedResult[model.UserHoliday], error) {
	modifiers := []helpers.PaginatedQueryFunc{
		helpers.TenantScope(parentUserID), // first, always; refuses a zero id
	}
	if query.IsActive != nil {
		modifiers = append(modifiers, func(db *gorm.DB) *gorm.DB {
			return db.Where("is_active = ?", *query.IsActive)
		})
	}
	if query.Year != nil {
		modifiers = append(modifiers, func(db *gorm.DB) *gorm.DB {
			return db.Where("holiday_date >= make_date(?, 1, 1) AND holiday_date < make_date(? + 1, 1, 1)",
				*query.Year, *query.Year)
		})
	}
	modifiers = append(modifiers, func(db *gorm.DB) *gorm.DB {
		return db.Order("holiday_date ASC")
	})

	var result helpers.PaginatedResult[model.UserHoliday]
	err := helpers.SafeDBQuery(func() error {
		var err error
		result, err = helpers.ExecutePaginatedQuery[model.UserHoliday](database.Db, query.PaginationParams, modifiers...)
		return err
	})
	if err != nil {
		return helpers.PaginatedResult[model.UserHoliday]{}, fmt.Errorf("list holidays: %w", err)
	}
	return result, nil
}
```

The rules:

- **Filters come from a typed query DTO**, one modifier per filter, each a `Where` with
  placeholders. A filter value never reaches SQL as text.
- **A sort the client chooses goes through a whitelist.** A `sort` query parameter is
  looked up in a `map[string]string` from client field name to column, and an unknown
  name is a 400, not silently ignored. There is no placeholder for an identifier, so a
  column name reaches the query as text or not at all, and the map's value is the only
  text that may.
- **No endpoint sets `Limit` past the executor.** `paginationParams.Limit = 200` in a
  handler "because the UI does not paginate" is a second ceiling, and it is the one
  that will be raised again next quarter. If a screen genuinely needs every row, it is
  a bounded export with its own endpoint and its own budget, not a list with the
  ceiling removed.
- **`count(*)` is a second query over the same predicate.** That is the price of a
  total, and the index the list uses has to serve it too
  (`references/data-layer.md`, "Tenancy").

## Identity comes from the credential, never the payload

There are two credentials, and each one decides where identity may come from.

**A user's JWT, on user-facing routes.** `RequireValidJWT` verifies the token and puts
an `Identity` in the Gin context. The handler reads the tenant from there. The DTO has
no field that could carry it.

```go
// internal/middleware/user_jwt_auth.go
package middleware

import (
	"net/http"
	"strconv"
	"strings"

	"example.com/users-service/internal/config"
	"example.com/users-service/internal/helpers"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

// Unexported: nothing outside this file can write the key, so nothing can overwrite
// the identity a verified token put there.
const identityKey = "middleware.identity"

type UserClaims struct {
	UserID    int    `json:"user_id"`
	AccountID string `json:"account_id"`
	Email     string `json:"email"`
	Role      string `json:"role"`
	jwt.RegisteredClaims
}

// Identity is what the token proved. A value, so a handler that receives it cannot
// widen its own permissions by mutating it.
type Identity struct {
	UserID    int
	AccountID int
	Email     string
	Role      string
}

func RequireValidJWT() gin.HandlerFunc {
	// Read once, at construction. LoadConfig already refused to boot without it, so an
	// empty secret here is impossible - and if it were possible, HMAC with an empty key
	// verifies tokens anybody can mint.
	secret := []byte(config.GlobalConfig.JwtSecret)

	return func(c *gin.Context) {
		raw, ok := strings.CutPrefix(c.GetHeader("Authorization"), "Bearer ")
		if !ok || raw == "" {
			c.AbortWithStatusJSON(helpers.RespondError("authorization header must be Bearer <token>", nil, http.StatusUnauthorized))
			return
		}

		var claims UserClaims
		_, err := jwt.ParseWithClaims(raw, &claims,
			func(*jwt.Token) (any, error) { return secret, nil },
			// The algorithm is pinned here, by us. Trusting the token's own header is the
			// alg-confusion family: alg "none", or RS256 downgraded to HS256 and signed
			// with your public key.
			jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
			// Absent exp is invalid, not eternal. A token with no expiry is one leak away
			// from permanent access.
			jwt.WithExpirationRequired(),
		)
		if err != nil {
			c.AbortWithStatusJSON(helpers.RespondError("invalid or expired token", nil, http.StatusUnauthorized))
			return
		}

		// A token that verifies but carries a zero user or an unparseable account is
		// malformed, not anonymous. Defaulting either to 0 scopes every query in this
		// request to tenant 0, which matches nothing until the day it matches everything.
		accountID, err := strconv.Atoi(claims.AccountID)
		if claims.UserID <= 0 || err != nil || accountID <= 0 {
			c.AbortWithStatusJSON(helpers.RespondError("invalid or expired token", nil, http.StatusUnauthorized))
			return
		}

		c.Set(identityKey, Identity{
			UserID:    claims.UserID,
			AccountID: accountID,
			Email:     claims.Email,
			Role:      claims.Role,
		})
		c.Next()
	}
}

// IdentityFrom returns two values, not one. An Identity{} zero value is
// indistinguishable from a real one at the call site, and a query scoped to user 0 is
// a query with no scope.
func IdentityFrom(c *gin.Context) (Identity, bool) {
	v, ok := c.Get(identityKey)
	if !ok {
		return Identity{}, false
	}
	id, ok := v.(Identity)
	return id, ok
}
```

**The internal secret, on service-to-service routes.** `InternalServicesAuth` proves
the caller is one of our services. That caller derived the tenant from a credential of
its own (the BFF from the user's JWT) and passes it in the path, and the path is
trustworthy for exactly one reason: the caller proved who it is on the line before.

```go
// internal/middleware/internal_services_auth.go
package middleware

import (
	"crypto/subtle"
	"net/http"

	"example.com/users-service/internal/config"
	"example.com/users-service/internal/helpers"

	"github.com/gin-gonic/gin"
)

// InternalServicesAuth fails CLOSED: an unset secret rejects every request rather than
// admitting everyone, and the compare is constant-time so the secret does not leak one
// byte at a time to anyone patient enough to time the 401s.
//
// The header only. Never a ?secret= query parameter: a secret in a URL is a secret in
// every access log, proxy log and browser history it passes through.
func InternalServicesAuth() gin.HandlerFunc {
	expected := []byte(config.GlobalConfig.InternalServicesWebhookSecret)
	return func(c *gin.Context) {
		got := []byte(c.GetHeader("X-Internal-Secret"))
		if len(expected) == 0 || subtle.ConstantTimeCompare(expected, got) != 1 {
			c.AbortWithStatusJSON(helpers.RespondError("unauthorized", nil, http.StatusUnauthorized))
			return
		}
		c.Next()
	}
}
```

The rules, together:

- **A user-facing DTO has no tenant field.** No `parent_user_id`, no
  `owner_account_id`, no `user_id`, no `role`. The fix is not to remember to overwrite
  the field from the token; it is that the field must not exist. A field the client can
  send is a field one convenient line of code will eventually trust.
- **A user-facing route has no tenant in the path.** `/v1/me/holidays`, not
  `/v1/holidays/user/:user_id`. A path param on a user-facing route is the payload by
  another name.
- **A route that takes a tenant in the path is mounted under `InternalServicesAuth`.**
  A tenant-in-path route on a public or JWT group lets any caller read any tenant by
  editing a number in a URL.
- **Another tenant's row is a 404, never a 403.** The service scopes the query by the
  tenant, so an id that belongs to someone else matches nothing and the service returns
  `ErrHolidayNotFound`. A 403 confirms the row exists, which is the fact you were
  hiding.
- **Anything the server owns is something the client may not assert.** Identity is the
  most dangerous instance, not the only one: a price, a status, a balance, a
  `created_at`. A `price` field on a create DTO is a client naming its own price.

## Swagger is generated from the handlers

Every handler carries a `godoc` block with `@Summary`, `@Tags`, `@Param` for every
path, query and body input, `@Success` and `@Failure` naming typed envelope structs,
`@Security`, and `@Router`. `swag init -g cmd/main.go` writes `docs/`, which is
generated and never hand-edited; `routes/swagger.go` serves it.

The envelope types for the docs live in `internal/swagger/` (`HolidayEnvelope`,
`ErrorEnvelope`), so `@Success 200 {object} map[string]interface{}` never appears. A
response documented as a map is a response a client generator cannot type, which puts
the frontend back to reading JSON by hand.

## Checklist

An endpoint is done when all of these are true. Any "no" is the bug you ship.

- It is registered in its resource's `setup<Name>Routes`, under a group whose auth
  matches its audience.
- Its handler parses, validates, delegates and responds, and a valid request has
  exactly one path through it.
- A binding failure goes through `BindingError`; a path id goes through `PathID`.
- Every error reaches the wire through `RespondServiceError`. No `err.Error()` is in
  any response body, and the handler chooses no status for an error.
- Its new failure mode, if it has one, is a sentinel in `contracts/errors.go` with a
  sentence written for the user.
- Its request DTO cannot express a tenant, a user id or a role, unless the route is
  internal.
- Its response is a `ResponseDTO` built by a helper, never a model.
- If it returns a list, it went through `ExecutePaginatedQuery` and `RespondPaginated`,
  and no handler raised the limit.
- It has a `godoc` block and `swag init` was re-run.
