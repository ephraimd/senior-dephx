# The HTTP layer

The edge. What a route is wired to, what a handler is allowed to do, and the one
shape every response wears on the way out.

The spine says layers do only their job, there is one response envelope, and every
list paginates through one executor. This is the code that makes those true.

## `router` is one function and it is the whole route table

`run` calls it in exactly one place (`references/composition-and-lifecycle.md`), so
`router` lives beside it in `package main`. It builds no dependency and owns no
resource: everything it needs was constructed in the root and handed to it. A router
that opens its own database handle is a second composition root, and the first one
does not know it exists.

```go
// cmd/api/router.go
package main

import (
	"net/http"
	"sync/atomic"

	"log/slog"

	"example.internal/svc/internal/config"
	"example.internal/svc/internal/httpx"
	"example.internal/svc/internal/order"
	"example.internal/svc/internal/user"
)

// router is called once, from run, with dependencies it did not build. Note what is
// NOT a parameter: no *sql.DB, no mailer, no logger of its own. If a handler needs
// something, it needs it through the service it was given, which is what keeps the
// dependency graph readable from run alone.
func router(
	cfg config.Config,
	log *slog.Logger,
	ready *atomic.Bool,
	userSvc *user.Service,
	orderSvc *order.Service,
) http.Handler {
	// Feature folders own their route tables. router names the features it mounts
	// and knows none of their paths - so adding an endpoint is a one-file change in
	// one folder, instead of a line in a central 200-line routes file that every
	// feature branch also edits and every merge conflicts on.
	api := http.NewServeMux()
	user.Routes(api, user.NewHandler(userSvc))
	order.Routes(api, order.NewHandler(orderSvc))

	mux := http.NewServeMux()

	// Probes are public: an orchestrator has no credential and will not get one.
	mux.Handle("GET /healthz", httpx.Health())
	mux.Handle("GET /readyz", httpx.Ready(ready))

	// One subtree, one auth boundary. Auth wraps the mount, not each route: a
	// per-route wrapper is a list someone appends to, and the endpoint they forget
	// to wrap is public forever with nothing to notice it.
	mux.Handle("/v1/", chain(api, httpx.RequireAuth(cfg.AuthSecret, log)))

	return chain(mux,
		httpx.Recover(log),
		httpx.RequestID(),
		httpx.Logging(log),
	)
}

// chain applies middleware outermost-first, so the call site reads in the order a
// request travels. mw[0] sees the request first and the response last.
func chain(h http.Handler, mw ...func(http.Handler) http.Handler) http.Handler {
	for i := len(mw) - 1; i >= 0; i-- {
		h = mw[i](h)
	}
	return h
}
```

`cfg.AuthSecret` is a `Config` field like every other input to this process:
`AuthSecret: mustEnv("AUTH_SECRET")` in `config.Load`. It is read once, at boot,
and a missing one refuses the deploy. An `os.Getenv("AUTH_SECRET")` inside
`RequireAuth` is a service that boots green and rejects every request, or worse
verifies every token against the empty string.

The route table itself:

```go
// internal/user/routes.go
package user

import "net/http"

// Routes registers this feature and nothing else. It takes the mux rather than
// returning one, because a feature that returns its own mux has an opinion about
// its own prefix, and then the prefix lives in two files.
func Routes(mux *http.ServeMux, h *Handler) {
	mux.Handle("GET /v1/users", http.HandlerFunc(h.List))
	mux.Handle("GET /v1/users/{id}", http.HandlerFunc(h.Get))
	mux.Handle("POST /v1/users", http.HandlerFunc(h.Create))
}
```

Method patterns are load-bearing. `mux.Handle("/v1/users", ...)` without a method
answers `DELETE /v1/users` with the list handler and a 200. The verb is part of the
route or the route is a guess.

### Middleware order is not a preference

Outermost to innermost: **recovery, request id, logging, auth.** Each position is
paid for by a specific failure.

- **Recovery outermost.** An unrecovered panic in a handler goroutine does not fail
  a request, it kills the process - along with every unrelated request in flight and
  every worker mid-write. Anything sitting outside recovery is code whose panic is
  an outage. Recovery goes first so that nothing is outside it.
- **Request id above logging.** Logging above request id logs nothing useful. A
  line with no correlation id cannot be joined to the other twenty the same request
  emitted, so the one time you need to reconstruct what happened you have a
  haystack sorted by timestamp and interleaved with two hundred other requests.
- **Logging above auth.** Put logging inside auth and every rejected request is
  invisible. A credential-stuffing run then leaves no trace in your access log, and
  the first evidence is the account that gets taken over.
- **Auth innermost, and only on the protected subtree.** Nothing sits between it and
  the handler, so nothing can drop or overwrite the identity it put in the context.

Recovery covers the request goroutine only. A panic in a goroutine a handler
started is still fatal, which is one more reason handlers do not start goroutines -
see `references/background-work.md`.

```go
// internal/httpx/middleware.go
package httpx

import (
	"encoding/binary"
	"encoding/hex"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"runtime/debug"
	"strings"
	"time"

	"example.internal/svc/internal/auth"
	"example.internal/svc/internal/domain"
)

const HeaderRequestID = "X-Request-Id"

func Recover(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				rec := recover()
				if rec == nil {
					return
				}
				// net/http panics with this value on purpose to abandon a
				// connection. Swallowing it turns the server's own control flow
				// into a bogus 500 and leaves the connection half-dead.
				if rec == http.ErrAbortHandler {
					panic(rec)
				}
				log.Error("handler panicked",
					"panic", rec,
					"method", r.Method,
					"path", r.URL.Path,
					"request_id", requestIDOf(w, r),
					"stack", string(debug.Stack()),
				)
				RespondError(w, r, domain.ErrInternal)
			}()
			next.ServeHTTP(w, r)
		})
	}
}

func RequestID() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			id := sanitiseID(r.Header.Get(HeaderRequestID))
			if id == "" {
				id = newID()
			}
			// Set on the response BEFORE the handler runs. Recover sits outside this
			// middleware, so its deferred closure only ever holds the request from
			// before this line replaced it - the context id is unreachable from
			// there. The header is the same object in both frames, which is why
			// requestIDOf falls back to it.
			w.Header().Set(HeaderRequestID, id)
			next.ServeHTTP(w, r.WithContext(WithRequestID(r.Context(), id)))
		})
	}
}

// An inbound id is a client writing directly into your log pipeline. Unbounded and
// unfiltered, that is log injection and a bill nobody budgeted.
func sanitiseID(s string) string {
	if len(s) == 0 || len(s) > 64 {
		return ""
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := c == '-' || c == '_' ||
			(c >= '0' && c <= '9') ||
			(c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z')
		if !ok {
			return ""
		}
	}
	return s
}

// Correlation, not a secret. math/rand/v2's top-level functions are safe for
// concurrent use, and a request id nobody authenticates does not need crypto/rand's
// syscall on every request.
func newID() string {
	var b [16]byte
	binary.LittleEndian.PutUint64(b[0:8], rand.Uint64())
	binary.LittleEndian.PutUint64(b[8:16], rand.Uint64())
	return hex.EncodeToString(b[:])
}

func Logging(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Probes are not traffic. Two of them at two-second intervals is 86,400
			// lines a day that describe nothing, and they price your log bill and
			// bury the line you were looking for.
			if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" {
				next.ServeHTTP(w, r)
				return
			}

			ctx, slot := withErrSlot(r.Context())
			r = r.WithContext(ctx)

			sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
			start := time.Now()
			next.ServeHTTP(sw, r)

			attrs := []any{
				"method", r.Method,
				"path", r.URL.Path,
				"status", sw.status,
				"bytes", sw.bytes,
				"took", time.Since(start),
				"request_id", RequestIDFrom(r.Context()),
			}
			if slot.err != nil {
				attrs = append(attrs, "err", slot.err.Error())
			}

			switch {
			case sw.status >= 500:
				log.Error("request failed", attrs...)
			case sw.status >= 400:
				log.Warn("request rejected", attrs...)
			default:
				log.Info("request", attrs...)
			}
		})
	}
}

// statusWriter exists because net/http will not tell you what status it sent.
type statusWriter struct {
	http.ResponseWriter
	status int
	bytes  int
	wrote  bool
}

func (w *statusWriter) WriteHeader(code int) {
	if w.wrote {
		return // the second WriteHeader is a bug; do not make it a log line per request
	}
	w.wrote = true
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	w.wrote = true // an implicit 200; the default in the struct literal is already right
	n, err := w.ResponseWriter.Write(b)
	w.bytes += n
	return n, err
}

// Unwrap is what lets http.ResponseController reach the real writer. Without it a
// wrapped writer silently breaks Flush and Hijack, and the bug shows up on exactly
// one endpoint - the streaming one, months later, with no obvious cause.
func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func RequireAuth(secret string, log *slog.Logger) func(http.Handler) http.Handler {
	v := auth.NewVerifier(secret) // built once, not per request

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok || raw == "" {
				RespondError(w, r, auth.ErrMalformed)
				return
			}
			c, err := v.Verify(raw, time.Now())
			if err != nil {
				RespondError(w, r, err)
				return
			}
			id := Identity{UserID: c.Sub, TenantID: c.Tenant, Role: c.Role}
			next.ServeHTTP(w, r.WithContext(WithIdentity(r.Context(), id)))
		})
	}
}
```

### The probes are two endpoints, not one

```go
// internal/httpx/health.go
package httpx

import (
	"net/http"
	"sync/atomic"

	"example.internal/svc/internal/domain"
)

type statusDTO struct {
	Status string `json:"status"`
}

// Health answers for the process and nothing else. Liveness that pings the database
// restarts every replica during a database blip, which turns a thirty-second
// dependency wobble into a full outage that you caused and the database did not.
func Health() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		RespondOK(w, r, http.StatusOK, statusDTO{Status: "alive"})
	}
}

// Ready is the flag run flips before it closes the listener. The 503 is what makes
// the drain in references/composition-and-lifecycle.md work: the load balancer stops
// routing here while the listener is still open, so the in-flight requests finish
// and the next ones never arrive.
func Ready(ready *atomic.Bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !ready.Load() {
			RespondError(w, r, domain.ErrUnavailable)
			return
		}
		RespondOK(w, r, http.StatusOK, statusDTO{Status: "ready"})
	}
}
```

Both go through the envelope. There is no carve-out, because a carve-out is how the
second one starts.

## The handler's four moves

**Parse. Validate. Delegate. Respond.** In that order, once each, and nothing else.

```go
// internal/order/handler.go
package order

type Handler struct{ svc *Service }

// The handler holds the concrete service from the same feature folder. There is no
// interface seam here and no test for this function in isolation, because after the
// rule below there is nothing in it worth mocking: it has no behaviour of its own.
func NewHandler(svc *Service) *Handler { return &Handler{svc: svc} }

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	var req createOrderRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil { // parse
		httpx.RespondError(w, r, err)
		return
	}
	if err := req.Validate(); err != nil { // validate: shape only
		httpx.RespondError(w, r, err)
		return
	}
	id, ok := httpx.IdentityFrom(r.Context())
	if !ok {
		httpx.RespondError(w, r, domain.ErrUnauthenticated)
		return
	}

	out, err := h.svc.Create(r.Context(), CreateOrder{ // delegate
		TenantID:   id.TenantID,
		ActorID:    id.UserID,
		CustomerID: req.CustomerID,
		SKU:        req.SKU,
		Qty:        req.Qty,
	})
	if err != nil {
		httpx.RespondError(w, r, err)
		return
	}
	httpx.RespondOK(w, r, http.StatusCreated, toOrderDTO(out)) // respond
}
```

### No branch in a handler may change an outcome

Every `if` above is an early return from a failed parse. Not one of them picks a
different answer for a request that is valid. That is the line, and it is not "no
`if` statements" - it is that a valid request has exactly one path through this
function.

```go
// ✘ Two business rules, living in one entry point.
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	...
	if req.Qty > 100 && id.Role != "wholesale" {
		httpx.RespondError(w, r, domain.ErrForbidden)
		return
	}
	if req.Qty > 10 {
		req.Priority = "bulk"
	}
	out, err := h.svc.Create(r.Context(), toInput(req, id))
	...
}
```

The importer creates orders. The queue consumer that replays a failed order creates
orders. The admin endpoint creates orders. None of them go through this function, so
three of the four paths do not have the wholesale rule and never had it. No test
fails, because the test for this rule is a handler test and the handler still passes
it. You find out from an invoice.

```go
// ✔ The rule is where the decision is made, so every caller gets it: this endpoint,
// the importer, the consumer, and the one somebody writes next year without reading
// this file.
func (s *Service) Create(ctx context.Context, in CreateOrder) (Order, error) {
	if in.Qty > bulkThreshold && in.ActorRole != RoleWholesale {
		return Order{}, fmt.Errorf("%w: bulk quantity requires wholesale", domain.ErrForbidden)
	}
	in.Priority = priorityFor(in.Qty)
	...
}
```

**Validate means shape, not truth.** `Qty > 0` is validation: it is a fact about the
JSON. `Qty <= stock` is a business rule: it needs the database and it needs to hold
for the importer too. The test is whether the answer can change while the request
stays byte-identical. If it can, it is not the handler's.

```go
// internal/order/dto.go

// The edge type. It maps to the wire and nowhere else, which is why the storage
// struct never appears in this file: a storage struct on the wire publishes every
// field anyone adds to it later, automatically, forever.
type createOrderRequest struct {
	CustomerID int64  `json:"customer_id"`
	SKU        string `json:"sku"`
	Qty        int    `json:"qty"`
}

// Validate reports every failure at once. Returning the first one turns a six-field
// form into six round trips and six chances for the client to give up.
func (r createOrderRequest) Validate() error {
	f := map[string]string{}
	if r.CustomerID <= 0 {
		f["customer_id"] = "required"
	}
	if r.SKU == "" {
		f["sku"] = "required"
	}
	if r.Qty < 1 || r.Qty > 10_000 {
		f["qty"] = "must be between 1 and 10000"
	}
	if len(f) > 0 {
		return &domain.ValidationError{Fields: f}
	}
	return nil
}
```

```go
// internal/httpx/decode.go

const maxBodyBytes = 1 << 20 // 1 MiB

// DecodeJSON is the only way a body enters this service.
func DecodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	// Unbounded, a 4 GiB POST is an OOM that any client can send, from a laptop,
	// with curl, on purpose or by accident.
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))

	// An unknown field is a 400. Silence means a client that misspelled "quantity"
	// gets a successful order for zero items - and a client that sends "tenant_id"
	// to an endpoint that has no such field gets no answer at all, when what you
	// wanted was to find out they tried.
	dec.DisallowUnknownFields()

	if err := dec.Decode(dst); err != nil {
		// The decoder's message names Go types and byte offsets. That is your
		// vocabulary, not the client's, and publishing it publishes your structs.
		return &domain.ValidationError{Fields: map[string]string{"body": "malformed json"}}
	}
	// Two JSON documents in one body is not one request. Accepting the first and
	// ignoring the second is how a smuggled payload gets ignored by you and counted
	// by something downstream.
	if dec.More() {
		return &domain.ValidationError{Fields: map[string]string{"body": "expected a single json object"}}
	}
	return nil
}
```

## The single envelope

**Every response goes through it. Success, failure, probe, redirect body, all of
them.** One handler writing bare JSON means every consumer needs two parsers, and
the second parser is the one that never gets tested because it only runs on the
error path nobody triggers on purpose.

```go
// internal/httpx/respond.go
package httpx

import (
	"encoding/json"
	"fmt"
	"net/http"

	"example.internal/svc/internal/paging"
)

// Envelope is the entire public shape of this service. Data is `any` because the
// envelope is generic over its payload - what goes IN it is always a typed DTO,
// never a map. A map[string]any here would move the contract out of the compiler
// and into a wiki page.
type Envelope struct {
	Success bool       `json:"success"`
	Data    any        `json:"data,omitempty"`
	Error   *ErrorBody `json:"error,omitempty"`
	Meta    *Meta      `json:"meta,omitempty"`
}

// Code is stable and machine-readable; Message is for a human reading a log.
// Clients branch on Code. If they have to branch on Message you can never reword
// it, and you will want to.
type ErrorBody struct {
	Code    string            `json:"code"`
	Message string            `json:"message"`
	Fields  map[string]string `json:"fields,omitempty"`
}

type Meta struct {
	RequestID string    `json:"request_id"`
	Page      *PageMeta `json:"page,omitempty"`
}

type PageMeta struct {
	Page       int   `json:"page"`
	PageSize   int   `json:"page_size"`
	Total      int64 `json:"total"`
	TotalPages int   `json:"total_pages"`
	HasNext    bool  `json:"has_next"`
}

func RespondOK(w http.ResponseWriter, r *http.Request, status int, data any) {
	write(w, r, status, Envelope{
		Success: true,
		Data:    data,
		Meta:    &Meta{RequestID: requestIDOf(w, r)},
	})
}

// RespondPage is RespondOK with the page block filled in. It exists so that no
// handler ever assembles that block by hand: two handlers computing total_pages is
// two rounding rules, and the client's "next" button breaks on whichever one got it
// wrong.
func RespondPage[T any](w http.ResponseWriter, r *http.Request, data any, p paging.Page[T]) {
	write(w, r, http.StatusOK, Envelope{
		Success: true,
		Data:    data,
		Meta: &Meta{
			RequestID: requestIDOf(w, r),
			Page: &PageMeta{
				Page:       p.Page,
				PageSize:   p.Size,
				Total:      p.Total,
				TotalPages: p.TotalPages,
				HasNext:    p.HasNext,
			},
		},
	})
}

func RespondError(w http.ResponseWriter, r *http.Request, err error) {
	status, body := statusFor(err)

	// The cause goes to the log, once, on the request's own line. The handler knows
	// the error and the middleware knows the status and the duration; the slot joins
	// them. The alternative is RespondError logging by itself, which needs either a
	// logger threaded through every handler signature or a global one - and the
	// global is exactly what the composition root exists to abolish.
	recordErr(r.Context(), err)

	write(w, r, status, Envelope{
		Success: false,
		Error:   &body,
		Meta:    &Meta{RequestID: requestIDOf(w, r)},
	})
}

func write(w http.ResponseWriter, r *http.Request, status int, env Envelope) {
	// Marshal BEFORE WriteHeader. json.NewEncoder(w).Encode after the status is on
	// the wire cannot fail usefully: the client already has a 200 and now gets half
	// an object, with no way to tell that from a truncated connection.
	buf, err := json.Marshal(env)
	if err != nil {
		recordErr(r.Context(), fmt.Errorf("marshal envelope: %w", err))
		buf = []byte(`{"success":false,"error":{"code":"internal","message":"internal error"}}`)
		status = http.StatusInternalServerError
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = w.Write(buf) // the client hung up; there is nobody left to tell
}
```

### The domain-error map lives in exactly one function

```go
// internal/domain/errors.go
package domain

import "errors"

// The vocabulary of failure for this service. Every layer speaks these; only this
// file defines them. A store returns ErrNotFound, a service wraps it with context,
// and the HTTP layer maps it once - which is the whole reason the map below can be
// one function instead of one guess per handler.
var (
	ErrInvalid         = errors.New("invalid")
	ErrUnauthenticated = errors.New("unauthenticated")
	ErrForbidden       = errors.New("forbidden")
	ErrNotFound        = errors.New("not found")
	ErrConflict        = errors.New("conflict")
	ErrUnavailable     = errors.New("unavailable")
	ErrInternal        = errors.New("internal")
)

// ValidationError carries the per-field detail a sentinel cannot. It satisfies
// errors.Is(err, ErrInvalid) as well, so a caller that does not care about fields
// does not have to know this type exists.
type ValidationError struct {
	Fields map[string]string
}

func (e *ValidationError) Error() string        { return "validation failed" }
func (e *ValidationError) Is(target error) bool { return target == ErrInvalid }
```

```go
// internal/httpx/status.go
package httpx

import (
	"errors"
	"net/http"

	"example.internal/svc/internal/domain"
)

// statusFor is the ONLY place in this service where an error becomes a status code.
// One function, so a rename of the map is a diff of one function, and so nobody has
// to grep for what a 409 means.
func statusFor(err error) (int, ErrorBody) {
	// errors.As before errors.Is: ValidationError also matches ErrInvalid, and the
	// version with fields is strictly more useful than the version without.
	var ve *domain.ValidationError
	if errors.As(err, &ve) {
		return http.StatusBadRequest, ErrorBody{
			Code:    "invalid",
			Message: "request is not valid",
			Fields:  ve.Fields,
		}
	}

	switch {
	case errors.Is(err, domain.ErrInvalid):
		return http.StatusBadRequest, ErrorBody{Code: "invalid", Message: "request is not valid"}
	case errors.Is(err, domain.ErrUnauthenticated):
		return http.StatusUnauthorized, ErrorBody{Code: "unauthenticated", Message: "authentication required"}
	case errors.Is(err, domain.ErrForbidden):
		return http.StatusForbidden, ErrorBody{Code: "forbidden", Message: "not permitted"}
	case errors.Is(err, domain.ErrNotFound):
		return http.StatusNotFound, ErrorBody{Code: "not_found", Message: "resource does not exist"}
	case errors.Is(err, domain.ErrConflict):
		return http.StatusConflict, ErrorBody{Code: "conflict", Message: "resource already exists"}
	case errors.Is(err, domain.ErrUnavailable):
		return http.StatusServiceUnavailable, ErrorBody{Code: "unavailable", Message: "temporarily unavailable"}
	default:
		// Unmapped is 500, and 500 says nothing. An error that reached here is one
		// this service never classified: the client gets a code it can retry on and
		// you get the cause in the log, with the request id, where it belongs.
		return http.StatusInternalServerError, ErrorBody{Code: "internal", Message: "internal error"}
	}
}
```

Note the three properties that make this hold: `errors.Is` matches through
`fmt.Errorf("%w", ...)`, so a service is free to wrap with context; the sentinels are
values, not strings, so the compiler finds every use; and the mapping is total,
because the `default` exists.

### What it replaces

```go
// ✘ The mapping, scattered, done on the error's prose.
func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	o, err := h.svc.Get(r.Context(), id)
	if err != nil {
		if err.Error() == "not found" {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	json.NewEncoder(w).Encode(o)
}
```

Four separate failures in nine lines:

- **The string compare is a contract nobody signed.** The day someone writes
  `fmt.Errorf("load order %d: %w", id, err)` the message stops being `"not found"`,
  the 404 silently becomes a 500, no test fails, and the client starts retrying a
  request that can never succeed.
- **`err.Error()` on the wire is a leak.** The driver's words are not words you
  chose to publish: `pq: duplicate key value violates unique constraint
  "users_tenant_id_email_key"` hands an attacker your table name, your column names,
  your uniqueness rules, and confirmation that the email exists. **Never return a raw
  database or third-party error to a client.** The client gets a code from the map
  above. The cause goes to the log.
- **`http.Error` writes `text/plain`.** Two of the three paths here are outside the
  envelope, so a client parsing JSON gets a parse error instead of your error.
- **The success path encodes the storage struct.** Every column anyone adds to
  `Order` from now on is published the moment it is added, including the one someone
  names `internal_margin_cents`.

## Pagination goes through one executor

`ExecutePaginatedQuery` is how a list leaves this service. Not "for the big tables" -
for all of them. "This table is small" is a statement about today and about your own
tenants, and the unbounded query is a full scan waiting for the tenant who makes it
fatal.

```go
// internal/paging/paging.go
package paging

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"strconv"

	"example.internal/svc/internal/domain"
)

const (
	DefaultSize = 25
	MaxSize     = 100 // the hard ceiling; there is no parameter that raises it
)

type Request struct {
	Page   int
	Size   int
	Column string // resolved from the whitelist, never client text
	Desc   bool
}

func (r Request) Offset() int { return (r.Page - 1) * r.Size }

// Sortable is the whitelist, and it is the entire injection defence. There is no
// placeholder for an identifier - `order by $1` sorts by the constant string $1, not
// by the column - so a sort column reaches the query as text or not at all. The map's
// VALUE is what reaches it, and the value was written here, in Go, by you.
type Sortable struct {
	Columns map[string]string // client field name -> physical column
	Default string            // a key of Columns
}

func Parse(q url.Values, s Sortable) (Request, error) {
	req := Request{Page: 1, Size: DefaultSize, Desc: true}

	if v := q.Get("page"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return Request{}, &domain.ValidationError{
				Fields: map[string]string{"page": "must be a positive integer"},
			}
		}
		req.Page = n
	}

	if v := q.Get("page_size"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return Request{}, &domain.ValidationError{
				Fields: map[string]string{"page_size": "must be a positive integer"},
			}
		}
		// Clamp, do not reject. A client asking for 10,000 gets 100 and a working
		// list. What it must never get is 10,000: an unbounded limit is a full read
		// that any client can trigger on any endpoint, and the tenant who triggers
		// it will be the one with the most rows and the shortest patience.
		req.Size = min(n, MaxSize)
	}

	field := q.Get("sort")
	if field == "" {
		field = s.Default
	}
	col, ok := s.Columns[field]
	if !ok {
		// Rejected, not ignored. Silently sorting by something else returns a
		// different answer than the one asked for, and a client that asked for
		// newest-first and got oldest-first reads that as corrupted data.
		return Request{}, &domain.ValidationError{
			Fields: map[string]string{"sort": "unknown sort field"},
		}
	}
	req.Column = col

	switch q.Get("order") {
	case "", "desc":
		req.Desc = true
	case "asc":
		req.Desc = false
	default:
		return Request{}, &domain.ValidationError{
			Fields: map[string]string{"order": "must be asc or desc"},
		}
	}
	return req, nil
}

// Querier is the smallest thing the executor needs, so a *sql.DB and a *sql.Tx both
// satisfy it and a paginated list works inside a transaction without a second copy.
type Querier interface {
	QueryRowContext(ctx context.Context, q string, args ...any) *sql.Row
	QueryContext(ctx context.Context, q string, args ...any) (*sql.Rows, error)
}

// Spec is the query minus its paging. Every string in it is written by the store.
// None of them ever come from a request - see Sortable for why that is not a style
// preference.
type Spec struct {
	Select   string // "o.id, o.customer_id, o.total_cents"
	From     string // "orders o"
	Where    string // "o.tenant_id = $1" - see the tenancy rule in data-layer.md
	Args     []any
	Tiebreak string // a UNIQUE column. Not optional. See below.
}

type Page[T any] struct {
	Items      []T
	Page       int
	Size       int
	Total      int64
	TotalPages int
	HasNext    bool
}

func ExecutePaginatedQuery[T any](
	ctx context.Context,
	db Querier,
	req Request,
	spec Spec,
	scan func(*sql.Rows) (T, error),
) (Page[T], error) {
	if spec.Tiebreak == "" {
		// Refused at the first call, in the first test, by the developer who wrote
		// it - instead of on page 2, in production, as a duplicate row that support
		// cannot reproduce.
		return Page[T]{}, errors.New("paging: spec has no tiebreak column")
	}

	// Not nil. A nil slice marshals to `null`, and `null` where a client's type says
	// array is a crash in every strictly-typed client you have - on the empty-result
	// path, which is the one nobody demos.
	out := Page[T]{Page: req.Page, Size: req.Size, Items: []T{}}

	countQ := "select count(*) from " + spec.From + " where " + spec.Where
	if err := db.QueryRowContext(ctx, countQ, spec.Args...).Scan(&out.Total); err != nil {
		return Page[T]{}, fmt.Errorf("count: %w", err)
	}

	dir := "asc"
	if req.Desc {
		dir = "desc"
	}

	// The tiebreak is appended to every order by, always, in the same direction.
	args := append(append([]any{}, spec.Args...), req.Size, req.Offset())
	listQ := fmt.Sprintf(
		"select %s from %s where %s order by %s %s, %s %s limit $%d offset $%d",
		spec.Select, spec.From, spec.Where,
		req.Column, dir, spec.Tiebreak, dir,
		len(spec.Args)+1, len(spec.Args)+2,
	)

	rows, err := db.QueryContext(ctx, listQ, args...)
	if err != nil {
		return Page[T]{}, fmt.Errorf("list: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		item, err := scan(rows)
		if err != nil {
			return Page[T]{}, fmt.Errorf("scan: %w", err)
		}
		out.Items = append(out.Items, item)
	}
	// rows.Err, always. Without it a connection that dropped mid-iteration returns a
	// short page and a nil error, and the caller reports the truncated list as the
	// complete one.
	if err := rows.Err(); err != nil {
		return Page[T]{}, fmt.Errorf("rows: %w", err)
	}

	out.TotalPages = int((out.Total + int64(req.Size) - 1) / int64(req.Size))
	out.HasNext = req.Page < out.TotalPages
	return out, nil
}
```

**Why the tiebreak is mandatory.** `order by created_at desc` over a table where
forty rows share a timestamp has no defined order among those forty. The database is
free to return them differently on each execution, and it will, because the plan
changes with the offset. `limit 25 offset 25` then hands page 2 rows the client
already saw on page 1, and skips rows that appear on no page at all. Nothing errors.
The count says 40, the client assembles 38 and does not know which two are missing.
A unique tiebreak - the primary key, always available, already indexed - removes the
whole class.

Offset paging still shifts under concurrent inserts: a row added at the head pushes
one row from page 1 onto page 2. The tiebreak fixes the *undefined* order, not the
*moving* one. That is a keyset-pagination conversation, and it starts with the
tiebreak column you already added.

`count(*)` is a second query over the same predicate. That is the price of a total,
and the price is paid on the same index the list uses.

### Used

```go
// internal/order/store.go

// Scope is the data layer's tenancy type and SafeDBQuery is its panic boundary; both
// are defined in references/data-layer.md. Scope is a parameter rather than a
// convention, so a list with no tenant to scope by does not compile.
func (s *Store) List(ctx context.Context, sc domain.Scope, req paging.Request) (paging.Page[Order], error) {
	if err := sc.Validate(); err != nil {
		return paging.Page[Order]{}, err
	}
	spec := paging.Spec{
		Select:   "o.id, o.tenant_id, o.customer_id, o.total_cents, o.status, o.created_at",
		From:     "orders o",
		Where:    "o.tenant_id = $1",
		Args:     []any{sc.TenantID},
		Tiebreak: "o.id", // primary key: unique by construction, indexed by definition
	}

	// A list is a query like any other: it goes through SafeDBQuery, so a nil map in
	// scanOrder is this request's 500 and not the whole process's last act.
	var page paging.Page[Order]
	err := dbx.SafeDBQuery(ctx, "order.List", func() error {
		var err error
		page, err = paging.ExecutePaginatedQuery(ctx, s.db, req, spec, scanOrder)
		return err
	})
	return page, err
}
```

```go
// internal/order/handler.go

// The whitelist is a package var next to the handler that uses it, because it is
// part of this endpoint's contract: adding a sortable field is an API change.
var orderSortable = paging.Sortable{
	Columns: map[string]string{
		"created_at": "o.created_at",
		"total":      "o.total_cents",
	},
	Default: "created_at",
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	req, err := paging.Parse(r.URL.Query(), orderSortable)
	if err != nil {
		httpx.RespondError(w, r, err)
		return
	}
	id, ok := httpx.IdentityFrom(r.Context())
	if !ok {
		httpx.RespondError(w, r, domain.ErrUnauthenticated)
		return
	}

	page, err := h.svc.List(r.Context(), domain.Scope{TenantID: id.TenantID}, req)
	if err != nil {
		httpx.RespondError(w, r, err)
		return
	}
	httpx.RespondPage(w, r, toOrderDTOs(page.Items), page)
}
```

```json
{
  "success": true,
  "data": [{ "id": 41, "customer_id": 9, "total_cents": 1200, "status": "paid" }],
  "meta": {
    "request_id": "0f9c2ad1c4b74e0a8c7e6b5a4d3c2b1a",
    "page": { "page": 1, "page_size": 25, "total": 1, "total_pages": 1, "has_next": false }
  }
}
```

## Identity comes from the credential, never the payload

The auth middleware verifies the token and puts an `Identity` in the context.
Handlers read it from there. Nothing else is a source of identity.

```go
// ✘ The edge type can express identity, so a client can send it.
type createOrderRequest struct {
	TenantID   int64  `json:"tenant_id"`
	CustomerID int64  `json:"customer_id"`
	SKU        string `json:"sku"`
	Qty        int    `json:"qty"`
}

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	var req createOrderRequest
	httpx.DecodeJSON(w, r, &req)
	// Every field in req came from the internet. TenantID included. This endpoint
	// now writes into any tenant the caller can guess an integer for, and the write
	// looks completely legitimate in every log and every audit trail you have.
	out, err := h.svc.Create(r.Context(), CreateOrder(req))
	...
}
```

Nobody writes that on purpose. It arrives by convenience: the service input needed a
`TenantID`, the request struct was right there, and one `CreateOrder(req)` conversion
saved four lines. The reviewer sees a struct conversion.

**The fix is not to remember to overwrite the field. It is that the field must not
exist.**

```go
// ✔ The wire type has no tenancy. There is nothing to forge, nothing to overwrite,
// and nothing to remember - the compiler enforces what code review otherwise has to
// catch on every diff, forever, including the diffs it does not get shown.
type createOrderRequest struct {
	CustomerID int64  `json:"customer_id"`
	SKU        string `json:"sku"`
	Qty        int    `json:"qty"`
}

// The internal input HAS tenancy, and it is required. A caller that does not supply
// it does not compile.
type CreateOrder struct {
	TenantID   int64
	ActorID    int64
	ActorRole  string
	CustomerID int64
	SKU        string
	Qty        int
}

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	var req createOrderRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		httpx.RespondError(w, r, err)
		return
	}
	if err := req.Validate(); err != nil {
		httpx.RespondError(w, r, err)
		return
	}
	id, ok := httpx.IdentityFrom(r.Context())
	if !ok {
		// Unreachable while this route is mounted under RequireAuth. It is here
		// because "unreachable" is a claim about the wiring, and the day someone
		// mounts this handler on the public mux, a 401 is the failure you want -
		// not a zero TenantID reading somebody else's orders.
		httpx.RespondError(w, r, domain.ErrUnauthenticated)
		return
	}

	out, err := h.svc.Create(r.Context(), CreateOrder{
		TenantID:   id.TenantID, // from the credential
		ActorID:    id.UserID,   // from the credential
		ActorRole:  id.Role,     // from the credential
		CustomerID: req.CustomerID,
		SKU:        req.SKU,
		Qty:        req.Qty,
	})
	if err != nil {
		httpx.RespondError(w, r, err)
		return
	}
	httpx.RespondOK(w, r, http.StatusCreated, toOrderDTO(out))
}
```

The mapping is four lines of typing that a struct conversion would have saved. Those
four lines are the security boundary. `DisallowUnknownFields` in `DecodeJSON` is the
second half of it: a client that sends `tenant_id` to this endpoint now gets a 400
that says the field does not exist, and you get a log line saying somebody tried.

The same rule holds for path and query parameters. `GET /v1/orders/{id}` is not
authorised by the URL: the store scopes by `sc.TenantID`, so an id belonging to
another tenant returns `ErrNotFound` and a 404. **Not a 403** - a 403 confirms the
row exists, which is the fact you were hiding.

### The context key is a type

```go
// internal/httpx/context.go
package httpx

import (
	"context"
	"net/http"
)

// An unexported int type. context.WithValue(ctx, "user", u) in two packages is one
// key: the second write silently overwrites the first, and the reader gets a value
// of a type it did not expect and asserts against, so the failure is a nil deref in
// a package that never heard of the writer. Nothing outside this file can construct
// a ctxKey, so nothing outside this file can collide with it.
type ctxKey int

const (
	ctxKeyIdentity ctxKey = iota
	ctxKeyRequestID
	ctxKeyErrSlot
)

// Identity is what the credential proved. It is a value: a handler that receives it
// cannot widen its own permissions by mutating it.
type Identity struct {
	UserID   int64
	TenantID int64
	Role     string
}

func WithIdentity(ctx context.Context, id Identity) context.Context {
	return context.WithValue(ctx, ctxKeyIdentity, id)
}

// Two returns, not one. An Identity{} zero value with TenantID 0 is indistinguishable
// from a real one at the call site, and a query scoped to tenant 0 is a query with no
// tenant scope at all.
func IdentityFrom(ctx context.Context) (Identity, bool) {
	id, ok := ctx.Value(ctxKeyIdentity).(Identity)
	return id, ok
}

func WithRequestID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, ctxKeyRequestID, id)
}

func RequestIDFrom(ctx context.Context) string {
	id, _ := ctx.Value(ctxKeyRequestID).(string)
	return id
}

// requestIDOf prefers the context and falls back to the response header. Recover
// sits outside RequestID, so the request its deferred closure holds predates the
// context that carries the id. The header does not have that problem: it is the same
// object in both frames.
func requestIDOf(w http.ResponseWriter, r *http.Request) string {
	if id := RequestIDFrom(r.Context()); id != "" {
		return id
	}
	return w.Header().Get(HeaderRequestID)
}

// errSlot carries the cause of a failure from RespondError up to the Logging
// middleware, which is the only place that knows the status and the duration. Written
// by the request's own goroutine and read after ServeHTTP returns, so there is no
// race and no mutex.
type errSlot struct{ err error }

func withErrSlot(ctx context.Context) (context.Context, *errSlot) {
	s := &errSlot{}
	return context.WithValue(ctx, ctxKeyErrSlot, s), s
}

func recordErr(ctx context.Context, err error) {
	if s, ok := ctx.Value(ctxKeyErrSlot).(*errSlot); ok && s.err == nil {
		s.err = err // the first error is the cause; the rest are consequences
	}
}
```

### The verifier

Identity is only as good as the check that produced it. This is the whole of it,
using the standard library, because a token check you cannot read is a token check
you have not audited.

```go
// internal/auth/token.go
package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"example.internal/svc/internal/domain"
)

// Every one of these satisfies errors.Is(err, domain.ErrUnauthenticated), so the
// status map in httpx already handles them and never has to learn this package
// exists. The client sees one 401 with one message; which of the three it was goes
// to the log, where it is a signal and not a hint for whoever sent it.
var (
	ErrMalformed    = fmt.Errorf("%w: malformed token", domain.ErrUnauthenticated)
	ErrBadSignature = fmt.Errorf("%w: bad signature", domain.ErrUnauthenticated)
	ErrExpired      = fmt.Errorf("%w: token expired", domain.ErrUnauthenticated)
)

type Claims struct {
	Sub    int64  `json:"sub,string"`
	Tenant int64  `json:"tid,string"`
	Role   string `json:"role"`
	Exp    int64  `json:"exp"`
}

type Verifier struct{ secret []byte }

func NewVerifier(secret string) *Verifier { return &Verifier{secret: []byte(secret)} }

// Verify checks the signature before it reads a single claim. Parse-then-verify is
// how a forged token gets used anyway: by the time the signature fails, a log line,
// a metric label or a cache key already carries the attacker's tenant id.
//
// now is a parameter, not a call to time.Now inside. Expiry is the one behaviour
// here that a test must control, and a test that has to sleep for it is a test
// somebody deletes.
func (v *Verifier) Verify(token string, now time.Time) (Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return Claims{}, ErrMalformed
	}

	// The algorithm is pinned HERE, by us, before anything else happens. Trusting the
	// token's own header is the alg-confusion family: the attacker sets alg to none
	// and you accept an unsigned token, or downgrades RS256 to HS256 and signs with
	// your public key, which you helpfully published.
	var hdr struct {
		Alg string `json:"alg"`
	}
	if err := decodeSegment(parts[0], &hdr); err != nil || hdr.Alg != "HS256" {
		return Claims{}, ErrMalformed
	}

	mac := hmac.New(sha256.New, v.secret)
	mac.Write([]byte(parts[0] + "." + parts[1]))
	want := mac.Sum(nil)

	got, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return Claims{}, ErrMalformed
	}
	// hmac.Equal, not bytes.Equal and never ==. A compare that returns early on the
	// first wrong byte leaks the signature one byte at a time to anyone patient
	// enough to time your 401s.
	if !hmac.Equal(got, want) {
		return Claims{}, ErrBadSignature
	}

	var c Claims
	if err := decodeSegment(parts[1], &c); err != nil {
		return Claims{}, ErrMalformed
	}
	// Absent exp is invalid, not eternal. A token with no expiry is one leak away
	// from permanent access with no revocation story.
	if c.Exp == 0 || now.After(time.Unix(c.Exp, 0)) {
		return Claims{}, ErrExpired
	}
	// A zero tenant scopes every query in this service to tenant 0, which matches
	// nothing until the day a migration inserts a row with a zero default.
	if c.Sub == 0 || c.Tenant == 0 {
		return Claims{}, ErrMalformed
	}
	return c, nil
}

func decodeSegment(s string, dst any) error {
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, dst)
}
```

## Checklist

An endpoint is done when all of these are true. Any "no" is the bug you ship.

- Its route is registered in its own feature folder's `Routes`, with a method.
- It is mounted under the auth subtree, or it is a probe.
- Its handler parses, validates, delegates, responds - and a valid request has
  exactly one path through it.
- Its request type cannot express a tenant, a user id, or a role.
- Its input to the service takes those three from `IdentityFrom`.
- Every response, including the failures, went through `RespondOK`, `RespondPage` or
  `RespondError`.
- No `err.Error()` from a driver, a vendor or a decoder is anywhere in the body.
- If it returns a list, it went through `ExecutePaginatedQuery` with a unique
  tiebreak.
- Its sort field came out of a `Sortable` whitelist.
- Its new failure mode, if it has one, is a sentinel in `domain` and a case in
  `statusFor`.
