# Inter-service

Calling another service you own, and calling one you do not. Two different problems
wearing the same `http.Client`.

A **peer** is a service built to this blueprint. It answers in the `Envelope` from
`references/http-layer.md`, it speaks the domain sentinels, and its team will take a
pull request against its contract. It gets a **client**.

A **vendor** is a third party. It answers in its own shape, fails in its own
vocabulary, and changes when it likes. It gets an **adapter**, and the adapter is
where its vocabulary dies.

The spine says typed DTOs at every boundary and `map[string]any` crossing one is a
contract no compiler can check. This is that rule at the edge of the process, where
the compiler stops being able to help you for free.

## A contract is declared once and imported

Two hand-kept copies of one struct are two truths. They agree on the day they are
written and drift on the first field added, and **the compiler is silent because both
copies compile**. The peer adds `due_on`, marks it required, and your copy does not
have it: your requests are now missing a field your struct cannot express, and the
first person to notice is a customer with no invoice.

The type lives in the peer's module, at the top level, deliberately **not** under
`internal/`.

```go
// example.internal/mailsvc/contract/invoice.go
//
// Owned by the mail service. Imported by its own handler and by every caller,
// including this one. One declaration, N importers, one truth.
//
// It is not under internal/ on purpose. internal/ is unimportable across modules, and
// that is the compiler saying the quiet part out loud: what is under internal/ is the
// peer's business, what is in contract/ is its promise. A peer whose handler decodes a
// struct that lives under its internal/ has not published a contract. It has a struct,
// and you are about to copy it.
package contract

// SendInvoiceRequest is the body of POST /v1/invoices.
//
// Note what is NOT here: no tenant, no actor. The scope travels in a header the
// caller's credential entitles it to set (see "Tenancy passes through unchanged"), and
// a request type that can express a tenant is a request the peer can be talked into
// misfiling. Same rule as the peer's own edge types in references/http-layer.md.
type SendInvoiceRequest struct {
	InvoiceID  string `json:"invoice_id"` // the caller's id, and the idempotency key
	CustomerID int64  `json:"customer_id"`
	TotalCents int64  `json:"total_cents"`
	DueOn      string `json:"due_on"` // RFC 3339 date
}

type SendInvoiceResponse struct {
	MessageID string `json:"message_id"`
	QueuedAt  string `json:"queued_at"`
}
```

Your `go.mod` requires `example.internal/mailsvc`. That dependency is the point: it is
visible, it is versioned, and `go get -u` is a diff you can read.

**Who owns it: the service that owns the endpoint.** You need a field, you open a pull
request in their repo. Adding the field to a local copy is not a contract change, it
is a lie you compile. This is the general rule stated once and applied everywhere in
this file: **the owner of a piece of state is the only writer of it.**

```go
// ✘ internal/mailer/dto.go - the copy. Nobody writes this to be difficult. The peer's
// module was not tagged yet, the deadline was Friday, and four fields is four fields.
type sendInvoiceRequest struct {
	InvoiceID  string `json:"invoice_id"`
	CustomerID int64  `json:"customer_id"`
	TotalCents int64  `json:"total_cents"`
	// DueOn was added by the peer six weeks later. This struct compiles without it,
	// forever, and no test in either repo fails.
}
```

## Read the peer's parsing code before you write the client

Its handler decides whether a field arrives as a path segment, a query parameter or a
body field. **A client that guesses wrong compiles perfectly and fails at runtime**,
usually as the peer's 500, which means it pages the peer's team for a bug in your
repo. They will debug it for an hour before they find out it is not theirs.

This is a procedure, not an attitude. Before you write or change one client method,
open the peer's code, in this order, and write the answer down. Not its docs. Not its
collection export. Its code.

1. **`<peer>/internal/<feature>/routes.go`.** The method and the path, from the mux
   pattern. `POST /v1/invoices` or `PUT /v1/invoices/{id}` are different endpoints. A
   method that does not match is a 405 you will read as "the peer is down".
2. **Is the mount under `RequireAuth`, or under `RequireService`?** Those need
   different credentials, and the credential is the peer team's to issue, never yours
   to guess.
3. **The handler named in `Routes`.** Read its first fifteen lines and answer three
   questions separately, because they are three different places a field hides:
   - `r.PathValue("id")` - the field is in the URL.
   - `r.URL.Query().Get("reason")` - the field is in the query string.
   - `httpx.DecodeJSON(w, r, &req)` - the field is in the body.
4. **The request struct that handler decodes into.** Its json tags are the wire names.
   `customer_id` is not `customerId`, and the difference is a zero value the peer
   accepts and mails to nobody.
5. **The service method the handler delegates to.** What does it require that the
   handler does not validate? That is the 500 you are about to cause.

Then check the answer against the contract package you are importing. If they
disagree, the peer's contract is stale, and that is a conversation in their repo
before it is a line in yours.

```go
// What step 3 looks like. Three fields, three places, in one handler.
func (h *Handler) Cancel(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64) // the URL
	if err != nil {
		httpx.RespondError(w, r, &domain.ValidationError{
			Fields: map[string]string{"id": "must be an integer"},
		})
		return
	}
	reason := r.URL.Query().Get("reason") // the query string

	var req contract.CancelInvoiceRequest // the body
	if err := httpx.DecodeJSON(w, r, &req); err != nil {
		httpx.RespondError(w, r, err)
		return
	}
	...
}
```

```go
// ✘ Path right, method right, contract type right, one field in the wrong place.
return client.JSON[contract.CancelInvoiceResponse](ctx, c.call(client.Call{
	Method: http.MethodPost,
	Path:   "/v1/invoices/41/cancel",
	Body:   cancelBody{Reason: "duplicate", Note: req.Note}, // reason is a QUERY param
}))
```

Half of these you get for free: `DisallowUnknownFields` in the peer's `DecodeJSON`
(`references/http-layer.md`) turns an invented body field into a 400 you find in your
first test. **The half it cannot catch is the field you left out.** The peer reads
`r.URL.Query().Get("reason")`, gets `""`, and its service writes an empty reason to a
nullable column for the next two years, or trips a `not null` and returns the 500 that
lands on their pager and in your postmortem.

## Typed clients, never raw maps or bare bytes

`map[string]any` at a service boundary is an unchecked contract. A renamed field
becomes a nil lookup at runtime instead of a build failure, on the path that only runs
when something has already gone wrong.

One package carries the plumbing every peer client shares. Each peer gets one thin
client on top of it, and each endpoint gets one method: **request type in, response
type out, the peer's envelope unwrapped, its errors turned into our sentinels.**

### The header names

```go
// internal/httpx/headers.go
package httpx

// These are the wire contract of this service's edge, which is what httpx is. Both
// sides of every call read them: the client below sets them, and RequireService further
// down reads them.
//
// They cannot live in internal/client. client imports httpx for RequestIDFrom, so httpx
// importing client back is an import cycle - and the compiler would refuse it, which is
// the compiler being right about the direction. The edge does not depend on the callers
// of the edge.
const (
	HeaderTenantID       = "X-Tenant-Id"
	HeaderCallerService  = "X-Caller-Service"
	HeaderIdempotencyKey = "Idempotency-Key"
)
```

### The credential shape

```go
// internal/client/token.go
package client

import "context"

// TokenFunc is how a credential reaches a request: asked for, per call, inside that
// call's own deadline. Never a string frozen on a struct at construction.
//
// See "Credentials arrive as a provider" for the failure this exists to prevent.
type TokenFunc func(ctx context.Context) (string, error)

// Static is the one credential that may arrive as a string: a shared secret read once
// by config.Load, which does not expire and is rotated by a deploy. It is normalised
// into a TokenFunc immediately, so there is exactly ONE code path that attaches a
// credential to a request and no second one to forget about.
func Static(s string) TokenFunc {
	return func(context.Context) (string, error) { return s, nil }
}
```

### The decode side of the envelope

```go
// internal/client/envelope.go
package client

import "encoding/json"

// The decode side of httpx.Envelope. It is the one shape in this document stated
// twice, and the reason is the compiler's, not a preference: httpx lives under
// internal/, so the peer's module cannot export it and this module cannot import it.
// Go's internal/ rule is right about that - the envelope is the peer's edge, not its
// API. What must never be re-typed is the PAYLOAD contract, which is peer-specific and
// changes when the peer's team ships. The envelope is fixed by this blueprint and is
// identical in every service built to it, so it is declared once HERE, for every peer,
// rather than once per peer.
//
// Data is json.RawMessage and not `any`. Unmarshalling into `any` produces
// map[string]any, which is precisely the unchecked contract this file exists to ban -
// it would put the map back one layer down where nobody looks for it.
type envelope struct {
	Success bool            `json:"success"`
	Data    json.RawMessage `json:"data"`
	Error   *errorBody      `json:"error"`
	Meta    *meta           `json:"meta"`
}

type errorBody struct {
	Code    string            `json:"code"`
	Message string            `json:"message"`
	Fields  map[string]string `json:"fields"`
}

type meta struct {
	RequestID string `json:"request_id"`
}
```

"Stated twice" is a debt, so it gets a guard rather than a comment:

```go
// internal/client/envelope_test.go
//
// The whole cost of the duplication, paid once. httpx.Envelope is this service's own
// response type and every peer built to this blueprint has the same one, so if a tag
// is renamed on the way out, this fails on the way in. A red build, instead of a nil
// Data on the error path nobody demos.
//
// The value below is not a response any handler would write - success:false with data
// is nonsense. The test is about field names, not semantics.
func TestEnvelopeMatchesHTTPX(t *testing.T) {
	raw, err := json.Marshal(httpx.Envelope{
		Success: false,
		Data:    json.RawMessage(`{"ok":true}`),
		Error:   &httpx.ErrorBody{Code: "not_found", Message: "resource does not exist"},
		Meta:    &httpx.Meta{RequestID: "abc"},
	})
	if err != nil {
		t.Fatal(err)
	}

	var got envelope
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if string(got.Data) != `{"ok":true}` {
		t.Fatalf("data tag drifted: %s", raw)
	}
	if got.Error == nil || got.Error.Code != "not_found" {
		t.Fatalf("error tag drifted: %s", raw)
	}
	if got.Meta == nil || got.Meta.RequestID != "abc" {
		t.Fatalf("meta tag drifted: %s", raw)
	}
}
```

### One call

```go
// internal/client/call.go
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"strconv"
	"time"

	"example.internal/svc/internal/domain"
	"example.internal/svc/internal/httpx"
)

const (
	maxResponseBytes = 4 << 20 // 4 MiB

	// Deliberately NOT background-work.md's maxAttempts, which is 8 and belongs to the
	// queue. One name carrying two values across two files is how a blueprint starts
	// lying to the person building from it.
	maxClientAttempts = 3
	pauseBase         = 200 * time.Millisecond
	pauseCeiling      = 10 * time.Second
)

// Call is one request to one peer. Every field is set by a client method, and none of
// them come from a request body.
type Call struct {
	HTTP  *http.Client // the peer client's, with its timeout already on it
	Base  string
	Token TokenFunc
	Peer  string // names the peer in errors and logs; never reaches the client

	Method string
	Path   string
	Scope  domain.Scope // travels with the call, always
	Body   any          // a typed contract struct, or nil

	// IdempotencyKey is what makes Retry safe on a write. It is the caller's own
	// stable id for the work - an invoice id, an order id - never a fresh uuid per
	// attempt, which is a new fact each time and defeats the entire mechanism.
	IdempotencyKey string
	Retry          bool
}

// JSON performs one call and unwraps the peer's envelope into T. It is for peers built
// to this blueprint and for nothing else: it assumes the Envelope, so a vendor gets an
// adapter instead. See "The vendor boundary".
func JSON[T any](ctx context.Context, c Call) (T, error) {
	var zero T

	// A zero tenant never leaves this process. Refused here, at the first call, in the
	// first test - not by the peer, which has no way to know the difference between a
	// caller with no scope and a caller whose scope is tenant zero.
	if err := c.Scope.Validate(); err != nil {
		return zero, err
	}
	// Refused at construction time too. "Retryable" without a key is a claim the code
	// makes and cannot back, and the day it retries a 504 is the day one invoice
	// becomes two.
	if c.Retry && c.Method != http.MethodGet && c.IdempotencyKey == "" {
		return zero, fmt.Errorf("%w: retryable %s %s has no idempotency key",
			domain.ErrInternal, c.Method, c.Path)
	}

	var body []byte
	if c.Body != nil {
		var err error
		if body, err = json.Marshal(c.Body); err != nil {
			return zero, fmt.Errorf("%w: marshal %s request: %v", domain.ErrInternal, c.Peer, err)
		}
	}

	attempts := 1
	if c.Retry {
		attempts = maxClientAttempts
	}

	for i := 1; ; i++ {
		out, err := once[T](ctx, c, body)
		if err == nil {
			return out, nil
		}
		var r *transient
		if !errors.As(err, &r) || i == attempts {
			return zero, err
		}
		if !wait(ctx, r.pause()) {
			// The context died mid-backoff: shutdown, or the client hung up. Returning
			// the peer's error here would blame them for our own cancellation.
			return zero, fmt.Errorf("%w: %s: %v", domain.ErrUnavailable, c.Peer, ctx.Err())
		}
	}
}

func once[T any](ctx context.Context, c Call, body []byte) (T, error) {
	var zero T

	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body) // a fresh Reader per attempt; a consumed one sends nothing
	}

	// NewRequestWithContext, never NewRequest. The caller's context is what makes a
	// cancelled request stop the whole chain instead of leaving this leg running
	// against a peer for a client that left.
	req, err := http.NewRequestWithContext(ctx, c.Method, c.Base+c.Path, rdr)
	if err != nil {
		return zero, fmt.Errorf("%w: build %s request: %v", domain.ErrInternal, c.Peer, err)
	}

	tok, err := c.Token(ctx) // asked for now, inside this deadline, not held since boot
	if err != nil {
		return zero, fmt.Errorf("%w: %s credential: %v", domain.ErrInternal, c.Peer, err)
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	req.Header.Set(httpx.HeaderTenantID, strconv.FormatInt(c.Scope.TenantID, 10))
	if c.IdempotencyKey != "" {
		req.Header.Set(httpx.HeaderIdempotencyKey, c.IdempotencyKey)
	}
	// Forward the id, do not mint one. The peer's RequestID middleware keeps an inbound
	// id if it survives sanitiseID, and ours is 32 hex characters, so it does. That is
	// the difference between one grep across both services and two haystacks.
	if id := httpx.RequestIDFrom(ctx); id != "" {
		req.Header.Set(httpx.HeaderRequestID, id)
	}

	res, err := c.HTTP.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return zero, fmt.Errorf("%w: %s: %v", domain.ErrUnavailable, c.Peer, ctx.Err())
		}
		// Dial refused, connection reset, TLS handshake: the request may never have
		// been read, which is the one failure class where a repeat is honest.
		return zero, &transient{err: fmt.Errorf("%w: %s unreachable: %v",
			domain.ErrUnavailable, c.Peer, err)}
	}
	defer res.Body.Close()

	// Bounded on the way IN as well as out. A peer that answers with a gigabyte -
	// because it broke, or because DNS now points at something that is not it - is your
	// OOM, and the pod that dies is yours.
	raw, err := io.ReadAll(io.LimitReader(res.Body, maxResponseBytes))
	if err != nil {
		return zero, &transient{err: fmt.Errorf("%w: read %s response: %v",
			domain.ErrUnavailable, c.Peer, err)}
	}

	var env envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		// Not JSON at all. That is a proxy's error page, or a redirect to a login form,
		// or a WAF. It is not the peer failing; it is something between you claiming to
		// be the peer, and the status code it sent is not the peer's opinion.
		return zero, fmt.Errorf("%w: %s answered %d with a non-json body",
			domain.ErrInternal, c.Peer, res.StatusCode)
	}
	if !env.Success {
		return zero, translate(c.Peer, res, env.Error)
	}

	var out T
	if err := json.Unmarshal(env.Data, &out); err != nil {
		return zero, fmt.Errorf("%w: decode %s data: %v", domain.ErrInternal, c.Peer, err)
	}
	return out, nil
}

// transient marks a failure that repeating could fix, and carries the peer's own
// Retry-After when it sent one. Unexported and unwrappable: callers of a client see
// domain sentinels, and errors.Is reaches straight through this to them.
type transient struct {
	err  error
	hint time.Duration
}

func (t *transient) Error() string { return t.err.Error() }
func (t *transient) Unwrap() error { return t.err }

func (t *transient) pause() time.Duration {
	// The peer's own number wins. A 429 that says "8s" and gets retried in 200ms is a
	// client arguing with a rate limiter it has already lost to, and the argument is
	// what turns a throttle into a ban.
	if t.hint > 0 {
		return min(t.hint, pauseCeiling)
	}
	// Flat and jittered, deliberately. Without jitter every request that failed in the
	// same second retries in the same millisecond, and the retry is the second outage.
	return pauseBase/2 + time.Duration(rand.Int64N(int64(pauseBase/2)+1))
}

// wait is a cancellable sleep. time.Sleep here would ignore shutdown, and then every
// deploy waits out a backoff for a request whose client left ninety seconds ago.
func wait(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}
```

### The peer's vocabulary stops here

```go
// internal/client/translate.go
package client

// translate turns the peer's failure into THIS service's vocabulary. Its codes stop at
// this function.
//
// A caller that has to know the peer said "not_found" is a caller coupled to a service
// it does not import. The day the peer renames a code, your handler's 404 becomes a
// 500, silently, with no compiler anywhere in either repo to notice - the string still
// compiles, it just never matches again.
func translate(peer string, res *http.Response, body *errorBody) error {
	code, msg := "unknown", "no error body"
	if body != nil {
		code, msg = body.Code, body.Message
	}
	// Only ever to the log. The peer's prose is not prose you chose to publish, exactly
	// as a driver's is not (references/http-layer.md).
	detail := fmt.Sprintf("%s: %d %s: %s", peer, res.StatusCode, code, msg)

	switch res.StatusCode {
	case http.StatusBadRequest:
		// OUR bug, not the user's. The request did not satisfy a contract we import, so
		// there is nothing the user could have typed differently. Passing this through
		// as a 400 blames them for our mistake and hides ours behind their retry.
		return fmt.Errorf("%w: %s", domain.ErrInternal, detail)

	case http.StatusUnauthorized, http.StatusForbidden:
		// OUR credential, not the user's. Mapping this to domain.ErrUnauthenticated
		// tells a logged-in user to log in again over a service secret they have never
		// held and cannot fix, and buries a rotation failure under support tickets.
		return fmt.Errorf("%w: %s", domain.ErrInternal, detail)

	case http.StatusNotFound:
		return fmt.Errorf("%w: %s", domain.ErrNotFound, detail)
	case http.StatusConflict:
		return fmt.Errorf("%w: %s", domain.ErrConflict, detail)

	case http.StatusTooManyRequests:
		return &transient{
			err:  fmt.Errorf("%w: %s", domain.ErrUnavailable, detail),
			hint: retryAfter(res.Header.Get("Retry-After")),
		}
	case http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		return &transient{
			err:  fmt.Errorf("%w: %s", domain.ErrUnavailable, detail),
			hint: retryAfter(res.Header.Get("Retry-After")),
		}

	case http.StatusInternalServerError:
		// NOT transient. A 500 is the peer failing in a way it did not classify, which
		// means it may well have written. Repeating it is a guess with a side effect.
		return fmt.Errorf("%w: %s", domain.ErrInternal, detail)

	default:
		return fmt.Errorf("%w: %s", domain.ErrInternal, detail)
	}
}

// Retry-After is seconds or an HTTP date, and a peer under load sends whichever its
// framework felt like. A parse failure is 0, which means "use our own pause" - never
// an error, because a header we could not read is not a reason to fail a call we could
// otherwise make.
func retryAfter(h string) time.Duration {
	if h == "" {
		return 0
	}
	if n, err := strconv.Atoi(h); err == nil && n > 0 {
		return time.Duration(n) * time.Second
	}
	if t, err := http.ParseTime(h); err == nil {
		if d := time.Until(t); d > 0 {
			return d
		}
	}
	return 0
}
```

Note what a caller of `mail.SendInvoice` can now do: `errors.Is(err, domain.ErrNotFound)`
and get a 404 out of `statusFor` for free, without importing the peer, without knowing
it has status codes at all.

### The peer client

`run` already builds this one (`references/composition-and-lifecycle.md`):

```go
mail := mailer.NewClient(cfg.MailerURL, cfg.MailerToken, 10*time.Second)
defer mail.Close() // owns an http.Transport
```

so the constructor's signature and `Close` are fixed by that call site, not by this
file.

```go
// internal/mailer/client.go
package mailer

const peerName = "mailer"

// Client OWNS the transport it built, so it exposes Close and the root defers it -
// one owner, named at construction (references/composition-and-lifecycle.md).
//
// That file sketches this struct with a `tok string` field to make the ownership
// point. This file owns the internals, and the credential is a TokenFunc: see
// "Credentials arrive as a provider" for why a string here is a production incident
// with a two-hour fuse. NewClient and Close are unchanged.
type Client struct {
	http  *http.Client
	tr    *http.Transport
	base  string
	token client.TokenFunc
}

// NewClient is the constructor run calls. The token is cfg.MailerToken: a shared
// secret, read once at boot, which does not expire. It is normalised into a TokenFunc
// on the next line and never stored as a string.
func NewClient(base, token string, timeout time.Duration) *Client {
	return NewClientWithToken(base, client.Static(token), timeout)
}

// NewClientWithToken is the constructor for a credential that expires.
func NewClientWithToken(
	base string,
	token client.TokenFunc,
	timeout time.Duration,
) *Client {
	tr := &http.Transport{
		MaxIdleConns:        64,
		MaxIdleConnsPerHost: 32,
		IdleConnTimeout:     90 * time.Second,
	}
	return &Client{
		tr: tr,
		// The zero-value http.Client waits forever. One peer that accepts a connection
		// and never answers then holds a goroutine, a socket and a pooled database
		// connection per request, indefinitely, and your service dies of a problem that
		// is not yours. There is no default here to fall back on: this line is it.
		http:  &http.Client{Transport: tr, Timeout: timeout},
		base:  base,
		token: token,
	}
}

func (c *Client) Close() { c.tr.CloseIdleConnections() }

// call fills the four fields that never vary per endpoint, so a new method is a path,
// a body and a decision about retry - and nothing else to get wrong.
func (c *Client) call(spec client.Call) client.Call {
	spec.HTTP, spec.Base, spec.Token, spec.Peer = c.http, c.base, c.token, peerName
	return spec
}

// SendInvoice: request type in, response type out, both imported from the peer.
//
// Retry is safe here and only here because InvoiceID is the idempotency key and it is
// OUR stable id for the invoice, not a fresh one per attempt.
func (c *Client) SendInvoice(
	ctx context.Context,
	sc domain.Scope,
	req contract.SendInvoiceRequest,
) (contract.SendInvoiceResponse, error) {
	return client.JSON[contract.SendInvoiceResponse](ctx, c.call(client.Call{
		Method:         http.MethodPost,
		Path:           "/v1/invoices",
		Scope:          sc,
		Body:           req,
		IdempotencyKey: req.InvoiceID,
		Retry:          true,
	}))
}
```

### What it replaces

```go
// ✘ Compiles. Ships. Fails in four separate ways, none of them at build time.
func (c *Client) SendInvoice(
	ctx context.Context,
	m map[string]any,
) (map[string]any, error) {
	b, _ := json.Marshal(m)
	res, err := http.Post(c.base+"/v1/invoices", "application/json", bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	var out map[string]any
	json.NewDecoder(res.Body).Decode(&out)
	return out["data"].(map[string]any), nil
}
```

- **`http.Post` uses `http.DefaultClient`**, whose `Timeout` is zero, which is
  forever. It also ignores `ctx` entirely, so a cancelled request keeps this leg alive
  against a peer nobody is waiting for.
- **`m["customer_id"]` is a contract nobody signed.** Rename it and the peer reads
  zero, mails nobody, and returns 200. Nothing fails. Ever.
- **`out["data"].(map[string]any)` panics** on an error response, because `data` is
  absent and the assertion is unchecked. Recovery catches it and it becomes a 500 with
  a stack trace pointing at a type assertion instead of at the peer that rejected you.
- **The status code is never read.** A 404, a 429 and a 503 are all "success" here.

**The one exception, and it does not generalise.** A gateway whose entire job is to fan
out to N peers and hand a UI one object may hold **the aggregate it returns** as a
loose map, because it has no domain of its own and the shape it emits is the union of
shapes it does not own. That is defensible exactly there. It stops being defensible the
moment something branches on a value inside that map: a branch is a domain rule, the
map is now a domain type in a disguise, and the rename that breaks it breaks it at
runtime on the path the UI uses most. And the exception is only ever about the
aggregate. **The calls the gateway makes are typed clients like everyone else's.**

## Every call is bounded, and the budget has to add up

Three bounds, and you need all three:

- **`http.Client.Timeout`**, set at construction, covering the whole exchange including
  reading the body. `10*time.Second` in `run`'s call above.
- **The caller's context**, propagated through `NewRequestWithContext`, so a cancelled
  request stops the whole chain rather than leaving each leg to time out alone.
- **A per-unit deadline for work that is not a request.** A queue consumer derives one
  from the root context (`references/background-work.md`); it does not inherit a
  request's, because it does not have one.

Then add them up, because nothing else will. The server in
`references/composition-and-lifecycle.md` has `WriteTimeout: 30 * time.Second`. A
handler that calls the mail service (10s) and then the CRM provider (10s) sequentially
has 20 seconds of somebody else's uptime inside a 30-second write budget, plus its own
queries. Add a third peer and the handler's own timeout is now the thing that fails,
and the log line will name your server, not the peer that was slow.

## Retries belong to the caller, and only for retryable things

The peer cannot retry for you: it does not know whether its answer arrived. So the
decision lives in the client, which is the only code that knows the verb and whether an
idempotency key went with it.

**Retrying a non-idempotent POST is how one order becomes three.** A 504 does not mean
the peer did not act. It means a proxy stopped waiting. The write may have committed a
millisecond after the gateway gave up, and your retry commits it again. That is why
`Call.Retry` on a non-GET without `IdempotencyKey` is refused in `JSON` rather than
documented: a rule you can forget is a rule for the incident review.

The key must be **the caller's stable id for the work** - the invoice id, the order id.
A fresh uuid per attempt is a new fact every time, and the peer dedupes nothing.
Honouring the key is the peer's obligation, and it is worth two minutes of step 5 in
the procedure above to confirm the peer's handler actually reads the header.

The in-process retry is deliberately shallow: three attempts, one jittered pause, no
curve. **The bounded-retry rule - exponential backoff, `maxAttempts`, `ErrPermanent`, a
terminus and a dead letter - is `references/background-work.md`'s, and it belongs to the
queue.** Do not build a second one here. Work that must survive a peer having a bad
afternoon gets enqueued, because a request goroutine cannot wait nine minutes: its
client is gone, its `WriteTimeout` fired, and the only thing still holding on is a
database connection nobody else can have.

## Tenancy passes through unchanged

The scope travels with the call. It is never re-derived by the peer from the payload,
and it never widens in transit.

The outbound half is already above: `Call.Scope` is a `domain.Scope`, `JSON` calls
`sc.Validate()` before it builds anything, and the value goes out as `X-Tenant-Id`. The
scope came from `IdentityFrom`, which came from the credential
(`references/http-layer.md`). Nothing on that path ever touched a request body.

The inbound half is the peer's, and it is why the header is trustworthy:

```go
// internal/httpx/service_auth.go
package httpx

// RequireService authenticates a CALLER SERVICE. RequireAuth authenticates a user.
// They are two middlewares because they answer two questions, and conflating them is
// how a user's token authorises an internal endpoint that assumed only a peer could
// reach it.
//
// The tenant is not in this credential and cannot be: one service secret serves every
// tenant. It arrives in a header, from a caller this middleware has just
// authenticated, and THAT is the whole reason the header is trustworthy and the body
// is not. The body is the user's data - it came from the internet. The header is the
// caller's assertion, and the caller proved who it is on the line above.
//
// cfg.ServiceSecrets is a Config field like every other input to this process
// (references/composition-and-lifecycle.md): caller=secret pairs, read once at boot,
// and a missing one refuses the deploy.
func RequireService(
	secrets map[string]string,
	log *slog.Logger,
) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			caller := r.Header.Get(HeaderCallerService)
			raw, hasPrefix := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			want, known := secrets[caller]

			// One branch, one answer, constant-time. An early return for an unknown
			// caller answers measurably faster than a wrong secret does, and that
			// difference is a way to enumerate your peers from the outside.
			if !hasPrefix || !known ||
				subtle.ConstantTimeCompare([]byte(raw), []byte(want)) != 1 {
				RespondError(w, r, domain.ErrUnauthenticated)
				return
			}

			n, err := strconv.ParseInt(r.Header.Get(HeaderTenantID), 10, 64)
			if err != nil || n <= 0 {
				// Refused, not defaulted. A missing tenant header defaulting to
				// anything is a query with no scope, and "no scope" against a
				// tenant-partitioned table returns whatever the planner finds first.
				RespondError(w, r, fmt.Errorf("%w: %s missing or invalid",
					domain.ErrInvalid, HeaderTenantID))
				return
			}

			// Reuses Identity, so handlers read it with IdentityFrom exactly as they do
			// for a user. UserID is zero because there IS no user: an internal endpoint
			// that needs an actor takes one in its contract, explicitly, rather than
			// writing a zero into an audit column and calling it provenance.
			id := Identity{UserID: 0, TenantID: n, Role: RoleService}
			next.ServeHTTP(w, r.WithContext(WithIdentity(r.Context(), id)))
		})
	}
}

// RoleService is what a service credential proves: a caller, a tenant, no person.
const RoleService = "service"
```

```go
// ✘ The peer, being helpful.
func (h *Handler) SendInvoice(w http.ResponseWriter, r *http.Request) {
	var req contract.SendInvoiceRequest
	if err := httpx.DecodeJSON(w, r, &req); err != nil { ... }

	// The customer id came from a body. The tenant is now looked up FROM it. The peer
	// has replaced a scope its caller proved with a scope an integer implied.
	sc, err := h.svc.TenantOfCustomer(r.Context(), req.CustomerID)
	...
}
```

One guessed integer and this peer reads, writes and emails inside a tenant its caller
never named. **A peer that infers the tenant from the body will eventually infer the
wrong one, and that is a data breach** - one that looks completely legitimate in every
log line, every audit trail and every metric you have, because as far as the peer is
concerned it did exactly what it was asked.

**Never widens** is the other half. A caller that has tenant 7 sends tenant 7. There is
no `X-Tenant-Id: *`, no "internal callers see everything", no admin bypass parameter.
The moment one exists, it is one misconfigured client away from being the normal case,
and nothing in the peer will notice because the request is valid.

## The owner of a piece of state is the only writer of it

This is the most transferable rule in this file. Everything above is a case of it.

Exactly one thing writes a given credential, a given table, a given fact. Everyone else
reads it, or asks the owner to change it. Two writers is not a race you can lock away.
It is two different beliefs about what the value means, held by two teams on two deploy
schedules, and the loser is whoever read in between.

- **One service owns a table.** A second service reaching into that database with its
  own handle is a schema dependency nobody declared: the owner's migration is now the
  other team's outage, and the owner will never know they caused it, because the code
  that broke is not in their repo and their tests all passed.
- **One process owns a resource and closes it**
  (`references/composition-and-lifecycle.md`). The same rule, one scope down.
- **One service owns a credential and refreshes it.** Below.

### Credentials arrive as a provider

```go
// ✘ The token, frozen at boot.
type Client struct{ token string }

func NewClient(base, token string) *Client { return &Client{token: token} }
```

This works in staging, where the credential is a long-lived test secret, and it works
in every test, and it passes review because it is four lines and there is nothing in
them. In production the credential is an access token with a one-hour life. The client
is built once, in `run`, with whatever the token was at boot. **At hour two every call
401s** - not at deploy, not under load, at hour two, with a green deploy an hour behind
it and nothing in the diff to blame. The rollback does not help, because the new
process captures a fresh token and buys you another hour.

`TokenFunc` is the fix, and it is above. `Static` is the narrow exception: a shared
secret from `config.Load` that does not expire and is rotated by a deploy. Everything
else asks.

**And it asks the owner.** The service that owns a credential is the only thing that
refreshes it:

```go
// internal/tokens/source.go
package tokens

// Source hands out this vendor's access tokens, per tenant, by ASKING the service that
// owns them. It caches, because a round trip per outbound call adds a second peer to
// every request path. It does not refresh - not "should not", cannot correctly.
//
// Two refreshers race. Most providers invalidate the old refresh token when they issue
// a new one, so the loser's refresh revokes the winner's freshly-minted access token,
// both services start 401ing at once, and the only thing that can fix it is a
// credential neither of them is allowed to mint. That outage lasts until a person is
// woken up, and it recurs every time both services are busy at the same moment - which
// is every time either of them matters.
type Source struct {
	peer *identity.Client
	skew time.Duration

	mu    sync.Mutex
	cache map[int64]entry // tenant -> token
}

type entry struct {
	token string
	exp   time.Time
}

func NewSource(peer *identity.Client) *Source {
	return &Source{peer: peer, skew: 60 * time.Second, cache: map[int64]entry{}}
}

func (s *Source) Token(ctx context.Context, sc domain.Scope) (string, error) {
	if err := sc.Validate(); err != nil {
		return "", err
	}

	s.mu.Lock()
	e, ok := s.cache[sc.TenantID]
	s.mu.Unlock()

	// The skew is not superstition. A token with 200ms left passes a bare
	// time.Now().Before(exp) and then 401s in flight, and the retry burns an attempt on
	// a failure that was arithmetic.
	if ok && time.Now().Add(s.skew).Before(e.exp) {
		return e.token, nil
	}

	fresh, err := s.peer.AccessToken(ctx, sc) // ask. never refresh.
	if err != nil {
		return "", err
	}

	s.mu.Lock()
	s.cache[sc.TenantID] = entry{token: fresh.Token, exp: fresh.ExpiresAt}
	s.mu.Unlock()
	return fresh.Token, nil
}

// For binds a scope into a TokenFunc. The binding IS the safety: a func for tenant 7
// cannot produce tenant 9's token, no matter which goroutine ends up holding it, and
// no caller anywhere in this service ever sees a token at all.
func (s *Source) For(sc domain.Scope) client.TokenFunc {
	return func(ctx context.Context) (string, error) { return s.Token(ctx, sc) }
}
```

The thing it asks is one more peer client, exactly the same shape:

```go
// internal/identity/client.go
package identity

const peerName = "identity"

type Client struct {
	http  *http.Client
	tr    *http.Transport
	base  string
	token client.TokenFunc
}

// The credential used to ASK for a credential is a shared secret from config: it does
// not expire, so Static is honest here.
func NewClient(base, secret string, timeout time.Duration) *Client {
	tr := &http.Transport{
		MaxIdleConns: 16, MaxIdleConnsPerHost: 8, IdleConnTimeout: 90 * time.Second,
	}
	return &Client{
		tr:    tr,
		http:  &http.Client{Transport: tr, Timeout: timeout},
		base:  base,
		token: client.Static(secret),
	}
}

func (c *Client) Close() { c.tr.CloseIdleConnections() }

// AccessToken asks the owner for this tenant's vendor token. GET, so Retry needs no
// idempotency key: there is nothing to duplicate.
func (c *Client) AccessToken(
	ctx context.Context,
	sc domain.Scope,
) (contract.AccessToken, error) {
	return client.JSON[contract.AccessToken](ctx, client.Call{
		HTTP: c.http, Base: c.base, Token: c.token, Peer: peerName,
		Method: http.MethodGet,
		Path:   "/v1/credentials/crm/token",
		Scope:  sc,
		Retry:  true,
	})
}
```

## The vendor boundary

A third party's types stop at one adapter package. Its vocabulary never reaches the
decision layer.

The interface is declared by the **consumer**, for the same reason `dbx.DB` is ours and
not `database/sql`'s: the side that needs a thing is the side that knows how little of
it it needs.

```go
// internal/order/service.go
//
// Declared here, by the code that needs it, and three lines long because three lines is
// what this service needs. The vendor's own client has ninety methods; an interface
// mirroring them would make the second vendor a rewrite of this file rather than a new
// package.
type CRM interface {
	UpsertContact(ctx context.Context, sc domain.Scope, c Contact) (CRMRef, error)
}

// Contact and CRMRef are OURS. The vendor's contact type has forty fields, a
// `Properties map[string]any` and an association spec. None of those words appear in
// this package, which is the entire point: when the vendor renames a field, the diff is
// inside the adapter and this file does not open.
type Contact struct {
	Email string
	Name  string
}

// The vendor's id is a string because it is the vendor's, and a wrapper type because
// the day it turns up next to our own int64 id, `crm.ID` and `order.ID` must not be
// assignable to each other by accident.
type CRMRef struct{ ID string }
```

```go
// internal/crma/adapter.go
//
// One adapter package per vendor, named for the vendor in a real repo. This document
// may not name one, so the two providers here are crma and crmb; read them as two
// suppliers of the same thing.
//
// Everything the vendor says stops in this package: its json shapes, its status codes,
// its rate-limit header, its idea of what a person is. What leaves is order.Contact,
// order.CRMRef, and domain sentinels.
package crma

// The compile-time proof that this satisfies the consumer's interface. Without it the
// failure lands in run, in a wiring diff, naming a type the reader has to go find. With
// it, the failure lands here, next to the method that is wrong.
var _ order.CRM = (*Adapter)(nil)

type Adapter struct {
	http   *http.Client
	tr     *http.Transport
	base   string
	tokens *tokens.Source // per tenant: this credential is the TENANT's, not ours
}

func NewAdapter(base string, src *tokens.Source, timeout time.Duration) *Adapter {
	tr := &http.Transport{
		MaxIdleConns: 32, MaxIdleConnsPerHost: 16, IdleConnTimeout: 90 * time.Second,
	}
	return &Adapter{
		tr:     tr,
		http:   &http.Client{Transport: tr, Timeout: timeout},
		base:   base,
		tokens: src,
	}
}

func (a *Adapter) Close() { a.tr.CloseIdleConnections() }

// upsertContactBody is the VENDOR's shape. Unexported, in this file, and nowhere else.
type upsertContactBody struct {
	Properties struct {
		Email     string `json:"email"`
		GivenName string `json:"given_name"`
	} `json:"properties"`
}

// upsertContactResult is also the vendor's. Note it is not an Envelope: client.JSON
// unwraps one, so it is for peers built to this blueprint and for nothing else. A
// vendor answers in its own shape and fails in its own vocabulary, which is precisely
// why it gets an adapter and a peer gets a client. This package is the only code in
// this service that knows what the vendor's 200 looks like.
type upsertContactResult struct {
	ObjectID string `json:"objectId"`
}

func (a *Adapter) UpsertContact(
	ctx context.Context,
	sc domain.Scope,
	c order.Contact,
) (order.CRMRef, error) {
	if err := sc.Validate(); err != nil {
		return order.CRMRef{}, err
	}

	// The scope is bound INTO the closure, not passed alongside it. A TokenFunc for
	// tenant 7 cannot produce tenant 9's token no matter who holds it.
	token := a.tokens.For(sc)
	tok, err := token(ctx)
	if err != nil {
		return order.CRMRef{}, fmt.Errorf("%w: crm credential: %v", domain.ErrInternal, err)
	}

	var body upsertContactBody
	body.Properties.Email, body.Properties.GivenName = c.Email, c.Name
	b, err := json.Marshal(body)
	if err != nil {
		return order.CRMRef{}, fmt.Errorf("%w: marshal crm contact: %v", domain.ErrInternal, err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.base+"/crm/v3/contacts",
		bytes.NewReader(b))
	if err != nil {
		return order.CRMRef{}, fmt.Errorf("%w: build crm request: %v", domain.ErrInternal, err)
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", "application/json")

	res, err := a.http.Do(req)
	if err != nil {
		return order.CRMRef{}, fmt.Errorf("%w: crm unreachable: %v", domain.ErrUnavailable, err)
	}
	defer res.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return order.CRMRef{}, fmt.Errorf("%w: read crm response: %v", domain.ErrUnavailable, err)
	}
	if res.StatusCode != http.StatusOK {
		// The vendor's own words go in the log line and no further. Its 409 becomes our
		// ErrConflict; the sentence it wrote about it stays here.
		return order.CRMRef{}, vendorErr(res.StatusCode, raw)
	}

	var out upsertContactResult
	if err := json.Unmarshal(raw, &out); err != nil {
		return order.CRMRef{}, fmt.Errorf("%w: decode crm response: %v", domain.ErrInternal, err)
	}
	return order.CRMRef{ID: out.ObjectID}, nil
}
```

The seam is real, so the second vendor costs one line:

```go
// in run (references/composition-and-lifecycle.md), where every dependency is named
var crm order.CRM = crma.NewAdapter(cfg.CRMBase, tokenSrc, 10*time.Second)
// becomes
var crm order.CRM = crmb.NewAdapter(cfg.CRMBase, tokenSrc, 10*time.Second)
```

`internal/order` never imports `crma`. `crma` imports `order` - it has to, it implements
`order.CRM` in terms of `order.Contact`. The arrow only ever points that way, and `run`
is the one place that names both.

**Not every dependency earns an interface.** `mailer.Client` is a concrete type on
`order.Service` (`references/data-layer.md`), and that is correct: it is our code, in
our module, built to this blueprint, and a test constructs it against an
`httptest.Server` that speaks the envelope. There is one implementation and there will
only ever be one. An interface with one implementation forever is an indirection with
no seam in it: every reader pays a jump to find out what actually runs, and nobody ever
gets to swap anything. The seam exists where the implementation is genuinely
replaceable, which is the vendor.

## What a provider does not tell you is part of its contract

Its docs list the events it emits. **The list you need is the complement, and nobody
publishes it.** Enumerate it before you build, in the repo, next to the code:

| We need to know | Does it webhook? | So |
|---|---|---|
| contact created, updated | yes | webhook |
| contact deleted | yes | webhook |
| two contacts merged | **no** | reconciler: a merge silently repoints an id we stored |
| pipeline renamed, stage added or removed | **no** | reconciler, every 15 minutes |
| a field's allowed values changed | **no** | reconciler |
| the account downgraded, disabling an endpoint we call | **no** | a 403 at runtime; alert |

Every **no** is a `Worker` you now own (`references/background-work.md`): an interval, a
bounded page through the provider's list endpoint, a diff against our rows. That is a
real cost and it belongs in the estimate, which is the first reason to write the table.

The second reason is that **the gap is found in production if you do not enumerate it up
front**, and it is not found as an error. It is found as a stale row: a stage that no
longer exists, still named in our dropdown, still selected by a user, still written to
our database. Nothing throws. No status code is wrong. There is no log line, because
nothing happened - that is the whole problem. Somebody notices in six weeks, and by
then the bad rows have children.

### Webhooks are at-least-once whether or not it says so

The provider retries anything that is not a clean 2xx, including the 200 your load
balancer ate on the way back. So the same event arrives twice, and **an endpoint that is
not idempotent processes it twice on the provider's first retry** - which is not a rare
event, it is Tuesday.

Dedupe on the provider's event id, in the index, exactly the way the queue does:

```sql
create table webhook_events (
    provider    text   not null,
    event_id    text   not null,
    tenant_id   bigint not null,
    received_at timestamptz not null default now(),

    -- The one table in this service whose key does not lead with tenant_id, and the
    -- exception is not laziness. The uniqueness we need is the PROVIDER's - its event
    -- id is unique in its namespace, not in ours - and the row is written before we
    -- have decided we trust anything in the payload. Leading with tenant_id here would
    -- let the same event id be processed once per tenant, which is the exact hole.
    primary key (provider, event_id)
);

-- Ours, for pruning and for the question "what did they send us for this tenant".
create index webhook_events_tenant_received on webhook_events (tenant_id, received_at desc);
```

```go
// internal/webhook/store.go

// Seen returns false the first time it sees an event and true every time after.
//
// The insert IS the check. A select-then-insert is two statements with a gap, and the
// provider's retry arrives in that gap: both replicas read "not seen", both process,
// and the customer gets two of whatever it was. The unique index does not have a gap.
//
// It takes a handle rather than using its own, because this write and the enqueue below
// are one fact (references/data-layer.md).
func (s *Store) Seen(
	ctx context.Context,
	db dbx.DB,
	provider, eventID string,
	sc domain.Scope,
) (bool, error) {
	if err := sc.Validate(); err != nil {
		return false, err
	}
	var inserted bool
	err := dbx.SafeDBQuery(ctx, "webhook.Seen", func() error {
		const q = `insert into webhook_events (provider, event_id, tenant_id)
		           values ($1, $2, $3)
		           on conflict (provider, event_id) do nothing
		           returning true`
		err := db.QueryRowContext(ctx, q, provider, eventID, sc.TenantID).Scan(&inserted)
		if errors.Is(err, sql.ErrNoRows) {
			return nil // conflict: nothing was returned, and that IS the answer
		}
		return err
	})
	return !inserted, err
}
```

```go
// internal/webhook/handler.go

func (h *Handler) Receive(w http.ResponseWriter, r *http.Request) {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxWebhookBytes))
	if err != nil {
		httpx.RespondError(w, r, &domain.ValidationError{
			Fields: map[string]string{"body": "unreadable"},
		})
		return
	}
	// The signature covers the bytes, so it is verified BEFORE they are parsed. Parse
	// first and an unsigned payload has already reached a log line, a metric label or a
	// cache key by the time you find out who sent it - which is nobody.
	if err := h.svc.VerifySignature(r.Header, raw); err != nil {
		httpx.RespondError(w, r, err)
		return
	}

	var ev crmEvent
	if err := json.Unmarshal(raw, &ev); err != nil { ... }

	// The tenant comes from the SIGNED body, and that is not a contradiction of the
	// tenancy rule. The signature is the credential here, and it covers these bytes, so
	// the account id inside them is exactly as proven as a claim inside a verified
	// token. What is banned is deriving a scope from an UNPROVEN payload.
	sc, err := h.svc.ScopeForAccount(r.Context(), ev.AccountID)
	if err != nil {
		httpx.RespondError(w, r, err)
		return
	}

	if err := h.svc.Accept(r.Context(), sc, ev); err != nil {
		httpx.RespondError(w, r, err)
		return
	}
	httpx.RespondOK(w, r, http.StatusOK, acceptedDTO{Accepted: true})
}
```

```go
// internal/webhook/service.go

// Accept is two writes and no work. The handler answers in milliseconds because a
// provider that does not get its 200 inside its own timeout retries - so doing the work
// inline means a slow job manufactures the duplicate that dedupe then has to catch.
func (s *Service) Accept(ctx context.Context, sc domain.Scope, ev crmEvent) error {
	return s.tx(ctx, func(tx *sql.Tx) error {
		// One transaction, deliberately. Two statements with a crash between them is an
		// event marked seen that nobody did: the provider will not send it again,
		// because we said 200, and dedupe has now deleted work instead of deduplicating
		// it. That is the one failure this whole mechanism exists to make impossible,
		// and it is the one nobody tests.
		seen, err := s.store.Seen(ctx, tx, providerName, ev.EventID, sc)
		if err != nil {
			return err
		}
		if seen {
			return nil // 200 below. See why.
		}
		return s.jobs.Enqueue(ctx, tx, syncContactJob{TenantID: sc.TenantID, ID: ev.ObjectID})
	})
}
```

A duplicate answers **200, not 409**. The provider is not asking a question, it is
delivering a fact it already delivered. Anything but a 2xx tells it to retry, so the
duplicate you just successfully detected comes back every minute, forever, and your
dedupe table becomes the thing generating the load.

## A peer being down is not you being down

`/readyz` reads the `ready *atomic.Bool` that `run` owns, and nothing else
(`references/http-layer.md`). It does not call the mail service. It does not ping the
CRM provider.

A readiness probe that checks a dependency propagates that dependency's outage into
yours **and multiplies it**. The mail service has a bad ten minutes; every replica of
every service that probes it goes unready; the load balancer pulls all of them; and now
the endpoints that never touch mail are 503 as well. One incident became four, and three
of them had working code. You did that, not them.

The exception is real and narrow: **if you cannot serve any request at all without it,
it is not a dependency, it is a component of you.** The database usually qualifies. The
test is one question: name an endpoint that still works while it is down. If you can
name one, your readiness stays green and the broken endpoint returns
`domain.ErrUnavailable` and a 503 of its own - which is the truth, scoped to the thing
that is actually broken.

And `/healthz` checks nothing but the process, for the reason `references/http-layer.md`
gives: liveness that pings a dependency restarts every replica during a blip, and turns
a thirty-second wobble into a full outage with your name on it.

## Checklist

A call to another service is done when all of these are true.

- Its request and response types are **imported from the peer's contract package**, not
  declared locally.
- Somebody opened the peer's `routes.go` and its handler, and knows which fields are
  path, which are query, and which are body.
- It goes through a typed client method: contract type in, contract type out.
- The peer's `Envelope` is unwrapped and its error codes are translated to `domain`
  sentinels. No caller learns the peer's vocabulary.
- No `map[string]any` anywhere, unless this is a gateway and the map is the aggregate it
  returns.
- The `http.Client` has a `Timeout`, the request carries the caller's context, and the
  sum of the peer timeouts on the hot handler fits inside `WriteTimeout`.
- Retry is off, or the verb is GET, or an `IdempotencyKey` that is a stable id goes with
  it. Anything durable is enqueued, not looped.
- `domain.Scope` is a parameter, `Validate()` ran before the request was built, and the
  scope left as a header the peer authenticated the caller to set.
- The peer reads the tenant from that header and never from the body.
- Credentials arrive as a `TokenFunc`. Nothing in this service refreshes a credential it
  does not own.
- A vendor's types, codes and words do not appear outside its adapter package, and the
  interface it satisfies is declared by the consumer.
- The list of events the provider does **not** emit is written down, and each one has a
  reconciler or an explicit decision not to have one.
- Every webhook endpoint verifies the signature before parsing, dedupes on the
  provider's event id in one transaction with the work it enqueues, and answers 200 to a
  duplicate.
- `/readyz` does not touch it.
