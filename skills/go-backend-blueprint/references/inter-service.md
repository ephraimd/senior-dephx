# Inter-service

Calling another service you own, and calling one you do not. Two different problems
wearing the same `http.Client`.

A **peer** is a service built to this blueprint. It answers in the `{message, data}`
envelope from `references/http-layer.md`, it authenticates internal callers with
`InternalServicesAuth`, and its team will take a change to its contract. It gets a
**typed client** in `pkg/<service>_client/`.

A **vendor** is a third party. It answers in its own shape, fails in its own vocabulary,
and changes when it likes. It gets an **adapter** in `pkg/<vendor>/`, and the adapter is
where its vocabulary stops.

The spine says typed DTOs at every boundary and `map[string]interface{}` crossing one is
a contract no compiler can check. This is that rule at the edge of the process, where
the compiler stops being able to help you for free.

## A peer client mirrors the peer's handler, field for field

The peer's handler and its DTOs are the source of truth. The client's DTOs in
`pkg/<service>_client/<service>_client.dto.go` are a mirror of them, kept in exactly one
place in the calling service.

- **One mirror per caller, in the client's dto file.** Never a second copy of
  `UserDTO` in a resource's `dto/` because it was closer. Two copies in one service
  drift on the first field added, and the compiler is silent because both compile.
- **The mirror changes when the peer changes, in a coordinated change.** A peer that
  adds a required field ships it as optional first, the callers' clients learn it,
  then it becomes required. Adding a field to your mirror that the peer does not send
  is not a contract change; it is a zero value you will read as real data.
- **Shared shapes that many services mirror** (a user, an account, a CRM config) live
  in `internal/contracts/<domain>.contracts.go` in each service, and are reviewed
  against the owner's DTO, not against each other.

## Read the peer's code before you write the client

The peer's handler decides whether a field arrives in the path, the query string or the
body. **A client that guesses wrong compiles and fails at runtime**, usually as the
peer's 500, which pages the peer's team for a bug in your repo.

This is a procedure. Before you write or change one client method, open the peer's
code, in this order, and write the answer down. Not its Swagger page, not a Postman
export. Its code.

1. **`internal/routes/routes.go`, its `setup<Name>Routes`.** The method and the path.
   `POST /v1/holidays/user/:user_id` and `PUT` on the same path are different endpoints.
2. **The group it is registered on.** `InternalServicesAuth` needs the internal secret
   header; `RequireValidJWT` needs a user token, which a service does not have and must
   not mint. A route on the JWT group is not callable service-to-service, and the fix
   is an internal route on the peer, not a forged token.
3. **The handler.** Read its first fifteen lines and answer three questions separately:
   - `c.Param("user_id")` / `helpers.PathID(c, "user_id")` - the field is in the URL.
   - `c.Query("parent_user_id")` / `c.ShouldBindQuery(&q)` - the field is in the query
     string, under the `form` tag's name.
   - `c.ShouldBindJSON(&input)` - the field is in the body, under the `json` tag's
     name.
4. **The DTO it binds into.** Its `json` and `form` tags are the wire names
   (`holiday_date`, not `holidayDate`), and its `binding` tags are the 400s you will
   get.
5. **The service method it calls.** What does it require that the handler does not
   validate? That is the 500 you are about to cause.

```go
// ✘ Path right, method right, one field in the wrong place.
// The peer reads parent_user_id with c.Query; this sends it in the body. Gin's
// ShouldBindJSON ignores the unknown field, c.Query returns "", PathID-style parsing
// turns "" into 0, and TenantScope refuses 0 with a 500 that lands on the peer's pager.
body := map[string]any{"parent_user_id": uid, "name": name}
```

## Typed clients, never maps, proxies or bare bytes

One wrapper carries the plumbing every client shares. Each peer gets one thin client on
top of it, and each endpoint gets one method: **typed request in, typed response out,
the envelope unwrapped, the peer's failure turned into a sentinel.**

```go
// pkg/httpclient/client.go
package httpclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// maxResponseBytes bounds what a peer can make us hold in memory. Unbounded, one
// misbehaving endpoint returning a 2 GB body is an OOM in a service that did nothing
// wrong.
const maxResponseBytes = 10 << 20

type HTTPClient struct{ client *http.Client }

// NewHTTPClient takes the timeout as a parameter: the whole exchange, body included.
// There is no constructor without one, because http.Client's default is no timeout at
// all, and a hung peer then holds the request goroutine forever.
func NewHTTPClient(timeout time.Duration) *HTTPClient {
	return &HTTPClient{client: &http.Client{Timeout: timeout}}
}

// Do is plumbing, and the ONLY method here that returns bytes. Client methods built on
// it never return bytes to their callers.
func (h *HTTPClient) Do(
	ctx context.Context,
	method, url string,
	headers map[string]string,
	body any,
) (int, []byte, error) {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return 0, nil, fmt.Errorf("marshal request: %w", err)
		}
		reader = bytes.NewReader(b)
	}
	// WithContext: the caller's deadline and cancellation reach the socket, so a
	// cancelled request stops the whole chain instead of each leg timing out alone.
	req, err := http.NewRequestWithContext(ctx, method, url, reader)
	if err != nil {
		return 0, nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := h.client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	return resp.StatusCode, data, err
}
```

```go
// pkg/users_client/client.go
package users_client

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"example.com/campaign-service/internal/contracts"
	"example.com/campaign-service/pkg/httpclient"
)

type UsersClient struct {
	baseURL string
	secret  string
	http    *httpclient.HTTPClient
}

// NewUsersClient cannot fail, so it returns the pointer alone. Its inputs come from
// Config, passed by SetupRouter: never read here.
func NewUsersClient(baseURL, internalSecret string) *UsersClient {
	return &UsersClient{baseURL: baseURL, secret: internalSecret, http: httpclient.NewHTTPClient(10 * time.Second)}
}

func (c *UsersClient) headers() map[string]string {
	return map[string]string{"X-Internal-Secret": c.secret}
}

// GetUser is one endpoint, one method. Its name is the domain operation, its result is
// a typed DTO, and its failure is a contracts sentinel. The caller never learns that an
// HTTP call happened.
func (c *UsersClient) GetUser(ctx context.Context, userID int) (UserDTO, error) {
	const op = "users-service GET /v1/user/{id}"
	status, body, err := c.http.Do(ctx, http.MethodGet, fmt.Sprintf("%s/v1/user/%d", c.baseURL, userID), c.headers(), nil)
	if err != nil {
		// The network failure goes in the chain, for the log. The sentinel decides the
		// client's 503.
		return UserDTO{}, fmt.Errorf("%s: %v: %w", op, err, contracts.ErrUpstreamUnavailable)
	}
	user, err := decodeData[UserDTO](op, status, body, "user")
	if errors.Is(err, contracts.ErrUpstreamNotFound) {
		// This method knows what a 404 means here, so it says it in this service's words.
		return UserDTO{}, fmt.Errorf("%s: %w", op, contracts.ErrUserNotFound)
	}
	return user, err
}
```

```go
// pkg/users_client/users_client.helper.go
package users_client

import (
	"encoding/json"
	"fmt"
	"net/http"

	"example.com/campaign-service/internal/contracts"
)

// decodeData unwraps the peer's {message, data: {<key>: ...}} envelope into T, and turns
// a failure status into a sentinel. Every method in this client goes through it, so
// there is one envelope parser per peer, not one per method.
func decodeData[T any](op string, status int, body []byte, key string) (T, error) {
	var zero T
	var env struct {
		Message string                     `json:"message"`
		Data    map[string]json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		// Not JSON at all: a proxy's HTML 502, a truncated body. That is the peer being
		// unavailable, whatever the status line said.
		return zero, fmt.Errorf("%s: undecodable response (status %d): %w", op, status, contracts.ErrUpstreamUnavailable)
	}
	if err := statusError(op, status, env.Message); err != nil {
		return zero, err
	}
	raw, ok := env.Data[key]
	if !ok {
		return zero, fmt.Errorf("%s: response has no data.%s: %w", op, key, contracts.ErrUpstreamUnavailable)
	}
	var out T
	if err := json.Unmarshal(raw, &out); err != nil {
		return zero, fmt.Errorf("%s: data.%s does not match the mirror: %v: %w", op, key, err, contracts.ErrUpstreamUnavailable)
	}
	return out, nil
}

func statusError(op string, status int, peerMessage string) error {
	switch {
	case status >= 200 && status < 300:
		return nil
	case status == http.StatusNotFound:
		return fmt.Errorf("%s: %w", op, contracts.ErrUpstreamNotFound)
	case status >= 400 && status < 500:
		// The peer's message is client-safe by the peer's own contract: it came out of
		// its RespondServiceError, so a human wrote it for a user. Passing it through is
		// right when the request carried the user's input to the peer, which is the BFF's
		// whole job. In any other service a peer's 4xx means THIS service built a bad
		// request, and the method should wrap it as an unclassified error instead.
		return fmt.Errorf("%s: %w", op, contracts.WithDetail(contracts.ErrUpstreamRejected, "%s", peerMessage))
	default:
		return fmt.Errorf("%s: status %d: %s: %w", op, status, peerMessage, contracts.ErrUpstreamUnavailable)
	}
}
```

```go
// internal/contracts/errors.go, continued: the words for a peer's failure.
var (
	ErrUpstreamNotFound    = NotFound("the requested record was not found")
	ErrUpstreamRejected    = Invalid("the request was rejected")
	ErrUpstreamUnavailable = Unavailable("a service this depends on is unavailable, please try again")
)
```

**Banned, in every client, including the BFF's:**

- **`map[string]interface{}` in a request or response DTO.** A renamed field becomes a
  nil lookup at runtime instead of a build failure, on the path that only runs when
  something has already gone wrong. The one exception is a BFF's **aggregate**: the
  object a gateway assembles from N peers for one screen may be a loose map, because it
  has no domain of its own. It stops being defensible the moment something branches on
  a value inside it, and it never extends to the calls the BFF makes, which are typed
  clients like everyone else's.
- **Generic proxy methods.** `ProxyGet(path, rawQuery string, ...) ([]byte, int, error)`
  is not a client, it is `curl` with extra steps: no typed request, no typed response,
  no sentinel, and a caller that now parses the peer's JSON itself, in every handler
  that uses it.
- **Raw `[]byte` from a client method.** The client owns unmarshalling and error
  translation. A method that returns bytes has handed both to every caller.
- **Forwarded raw query strings or bodies.** The handler binds a typed DTO; the client
  builds `url.Values` or a request struct from it, field by field. Forwarding
  `c.Request.URL.RawQuery` lets a client send the peer parameters this service never
  validated, including `parent_user_id`.
- **A handler calling a client directly.** Handlers call a service; the service calls
  the client. Even when the service is a thin pass-through today, it is the seam where
  caching, enrichment and the next business rule will go, and a handler that calls the
  client directly is a handler that will grow that rule itself.

## Every call is bounded, and the budget has to add up

Three bounds, all required:

- **The `http.Client` timeout**, set at construction in `NewHTTPClient`.
- **The caller's context**, passed to `Do`, so a cancelled request stops the chain.
- **A per-unit deadline for work that is not a request.** A job derives one from the
  root context (`references/background-work.md`).

Then add them up, because nothing else will. A handler with a 30-second `WriteTimeout`
that calls the users service (10s) and then a CRM (30s) sequentially has 40 seconds of
somebody else's uptime inside a 30-second budget. The response is cut mid-write, and the
log names this server, not the peer that was slow.

**When the sum does not fit, the work is not synchronous.** Paging a customer's entire
CRM book through the vendor's rate limiter inside one request takes as long as the book
is big. Raising `WriteTimeout` to two minutes to make it fit moves the ceiling without
removing it: the next customer's book is bigger, and every slow request now holds a
connection for two minutes. That endpoint is a Pattern C job that the client polls, or
a Pattern B sync that keeps a read model current.

## Retries belong to the caller, and only for retryable things

The peer cannot retry for you: it does not know whether its answer arrived.

- **GETs may be retried**, at most twice, with a short jittered pause, only on a network
  error or a 502/503/504.
- **A non-idempotent POST is never retried** unless it carries an idempotency key the
  peer honours. A 504 does not mean the peer did not act; it means a proxy stopped
  waiting. The write may have committed a millisecond later, and the retry commits it
  again. The key is **the caller's stable id for the work** (the deal id, the invoice
  id), never a fresh uuid per attempt, which is a new fact every time.
- **Anything that needs minutes of retrying is a job** on the queue, with the bounded
  retry and the dead letter that `references/background-work.md` owns. Do not build a
  second retry policy in a client.

## Tenancy passes through, unchanged and never widened

The tenant travels with the call and never changes on the way.

- **The BFF takes it from the JWT** (`middleware.IdentityFrom`) and puts it in the path
  or query of the internal route it calls. Never from the user's request body or query.
- **A peer takes it from the path or query of a route under `InternalServicesAuth`.**
  That value is trustworthy because the caller authenticated with the internal secret
  on the line before, and derived the tenant from a credential of its own.
- **A peer never infers the tenant from the payload.** Looking up the tenant from a
  `deal_id` in the body replaces a scope the caller proved with a scope an integer
  implied. One guessed integer and the peer reads, writes and emails inside a tenant
  its caller never named, and every log line says it did exactly what it was asked.
- **It never widens.** There is no `parent_user_id=0` meaning "all", no
  `?all_tenants=true`, no admin bypass parameter on an internal route. The moment one
  exists it is one misconfigured client away from being the normal case. `TenantScope`
  refuses the zero, which is the line of defence that holds when the client is wrong.

## The owner of a piece of state is the only writer of it

This is the most transferable rule in this file. Exactly one service writes a given
table, a given credential, a given fact. Everyone else reads it, or asks the owner.

- **One service owns a table.** It is the only one that writes it and the only one that
  lists it in `MigrateDB` (`references/data-layer.md`). A second service writing it
  through its own `database.Db` is a schema dependency nobody declared: the owner's next
  migration is the other team's outage, and the owner will never know, because the code
  that broke is not in their repo.
- **One service owns a credential and refreshes it.** OAuth tokens for a CRM are
  written, refreshed and rotated by exactly one service. Every other service asks it for
  a current token over an internal route, per use, and never refreshes locally. Two
  services refreshing the same rotating refresh token invalidate each other's: the
  first refresh succeeds and burns the token, the second fails, and the second service
  marks the integration disconnected for a customer whose integration is fine.
- **One flag is the kill switch.** When a feature can be turned off (a campaign's CRM
  sync), one column is the master switch and every path that does the work checks it
  first. Two switches is two answers to "is this on", and the path that checks the
  other one keeps writing to a customer's CRM after they turned it off.

## The vendor boundary

A third party's types stop at one adapter package. Its vocabulary never reaches a
service.

```go
// pkg/crm/adapter.go

// CRMAdapter is declared by the CONSUMER and is only as wide as the consumer needs.
// The vendor's SDK has ninety methods; an interface mirroring them makes the second
// vendor a rewrite of this file instead of a new package.
type CRMAdapter interface {
	CreateDeal(ctx context.Context, deal dto.CreateDealDTO) (dto.DealResponseDTO, error)
	UpdateDeal(ctx context.Context, crmDealID string, update dto.UpdateDealDTO) (dto.DealResponseDTO, error)
	ListPipelines(ctx context.Context) ([]dto.PipelineDTO, error)
}

// NewCRMAdapter is the one switch on the provider. The provider names are contracts
// constants; a provider string literal anywhere else is a second spelling of a fact.
func NewCRMAdapter(cfg contracts.CrmConfig, tokens TokenSource) (CRMAdapter, error) {
	switch contracts.CrmID(cfg.Provider) {
	case contracts.CrmIDA:
		return crma.New(cfg, tokens), nil
	case contracts.CrmIDB:
		return crmb.New(cfg, tokens), nil
	default:
		return nil, fmt.Errorf("crm provider %q: %w", cfg.Provider, contracts.ErrCrmNotSupported)
	}
}
```

```go
// pkg/crm/crma/adapter.go

// The compile-time proof. Without it the mismatch lands in SetupRouter, naming a type
// the reader has to go find; with it, it lands here, next to the method that is wrong.
var _ crm.CRMAdapter = (*Adapter)(nil)
```

- **The adapter translates in both directions**: our DTO into the vendor's request, the
  vendor's response into our DTO, the vendor's errors into our sentinels (a 401 from the
  vendor is `contracts.ErrCrmDisconnected`, a 429 is `ErrUpstreamUnavailable` with the
  retry-after in the chain).
- **A peer client has no interface.** There is one users service and there will only be
  one. The seam is where an implementation is genuinely replaceable, which is the vendor.

## What a provider does not tell you is part of its contract

Its docs list the events it sends. **The list you need is the complement, and nobody
publishes it.** Write it down, in the repo, next to the adapter:

| We need to know | Does it webhook? | So |
|---|---|---|
| deal created, updated, deleted | yes | webhook |
| two contacts merged | **no** | reconciler: a merge silently repoints an id we stored |
| pipeline renamed, stage added or removed | **no** | reconciler, hourly |
| our webhook subscription was deleted on their side | **no** | reconciler re-provisions it |
| the account downgraded, disabling an endpoint we call | **no** | a 403 at runtime; alert |

Every **no** is a Pattern B worker you now own. The gap is otherwise found in production
as a stale row, not an error: a stage that no longer exists, still in our dropdown,
still selected by a user. Nothing throws, because nothing happened.

## Webhooks

Providers deliver at least once, whether or not their docs say so. They retry anything
that is not a 2xx inside their own timeout, including the 200 your load balancer ate.

```go
// internal/resources/webhook_resource/webhook.handler.go

func (h *WebhookHandlerImpl) Receive(c *gin.Context) {
	raw, err := io.ReadAll(io.LimitReader(c.Request.Body, maxWebhookBytes))
	if err != nil {
		c.JSON(helpers.RespondServiceError(helpers.BindingError(err)))
		return
	}
	// The signature covers the bytes, so it is verified BEFORE they are parsed. Parse
	// first and an unsigned payload has already reached a log line or a cache key by the
	// time you find out who sent it, which is nobody.
	if err := h.service.VerifySignature(c.Request.Header, raw); err != nil {
		c.JSON(helpers.RespondServiceError(err))
		return
	}

	err = h.service.Accept(c.Request.Context(), raw)
	switch {
	case err == nil, errors.Is(err, contracts.ErrNonRetryable):
		// A payload we will never be able to process is acknowledged, not refused. A
		// provider that sees enough non-2xx answers disables the subscription, and then
		// every customer's sync stops, for one malformed event.
		if err != nil {
			logger.Logger.Warnf("webhook dropped as non-retryable: %v", err)
		}
		c.JSON(helpers.RespondOk("accepted", nil))
	default:
		c.JSON(helpers.RespondServiceError(err)) // a real failure: let the provider retry
	}
}
```

- **Dedupe on the provider's event id, in the database, in the same transaction as the
  work.** A table keyed `(provider, event_id)` with a unique index; `Accept` inserts the
  event row with `ON CONFLICT DO NOTHING` and, only if the insert took, writes the row
  the worker will act on, in one `SafeDBTransaction`. Two statements with a crash
  between them is an event marked seen that nobody did: the provider will not resend
  it, because we said 200. A Redis `SET NX` with a TTL is a fine pre-filter in front of
  this, never a substitute for it.
- **A duplicate answers 200.** The provider is delivering a fact it already delivered.
  Anything else tells it to retry, and the duplicate you correctly detected comes back
  every minute forever.
- **The handler does no work.** It verifies, dedupes, records, and answers in
  milliseconds. Doing the work inline means a slow job manufactures the timeout that
  manufactures the duplicate.
- **Echo guards.** When this service writes to a CRM, the CRM sends the change back as a
  webhook. Without a guard, that echo is processed as a user's edit, which may trigger a
  write, which echoes. Record what this service last wrote (a version, a hash, the
  integration's own user as the modifier) and drop the event that matches it.
- **The tenant comes from the signed payload** (the provider's account id, mapped to
  our tenant by the owner of that mapping). That is not a breach of "never from the
  payload": the signature is the credential here, and it covers these bytes.

## A peer being down is not you being down

`/healthz` checks the process and nothing else. It does not call the users service and
it does not ping the CRM.

A probe that checks a dependency propagates that dependency's outage into yours **and
multiplies it**: the peer has a bad ten minutes, every replica of every service that
probes it is restarted or pulled, and the endpoints that never touch that peer are down
too. One incident becomes four, and three of them had working code.

The broken endpoint returns `contracts.ErrUpstreamUnavailable` and a 503 of its own,
which is the truth, scoped to the thing that is actually broken.

## Checklist

A call to another service is done when all of these are true.

- Somebody opened the peer's `routes.go`, its handler and its DTO, and knows which
  fields are path, query and body, and which group the route is on.
- It is a typed client method in `pkg/<service>_client/`: domain-named, `ctx` first,
  typed DTO in, typed DTO out, mirrored in exactly one dto file.
- It sends `X-Internal-Secret` from `Config`, never from a literal.
- The envelope is unwrapped by the client's one `decodeData`, and every failure is a
  `contracts` sentinel. No caller sees a status code or a peer's raw body.
- No `map[string]interface{}`, no `Proxy*`, no `[]byte` returned, no forwarded raw
  query or body, no handler calling a client directly.
- The client has a timeout, the request carries the caller's context, and the sum of
  peer timeouts on the hot path fits inside `WriteTimeout`.
- Retry is off, or the verb is GET, or a stable idempotency key goes with it. Anything
  durable is a job.
- The tenant came from a credential, travels in the path or query to an internal route,
  and is never inferred from a payload or widened.
- This service writes nothing it does not own, and refreshes no credential it does not
  own.
- A vendor's types stop in its adapter, the interface is the consumer's, and the events
  the provider does not send each have a reconciler or a written decision not to.
- Every webhook verifies the signature before parsing, dedupes in the same transaction
  as its work, answers 200 to a duplicate and to a non-retryable payload, and guards
  against its own echoes.
