# Porting Portable Judgment Into senior-dephx — Design

- **Date:** 2026-07-02
- **Status:** Approved design — pending implementation plan
- **Branch:** `feat/portable-judgment-port`
- **Target version:** 0.2.0

## 1. Context

The doctrine in this plugin was written from scratch. In parallel, a production
Go/Java microservice codebase accumulated ~10 project-level skills containing the same
author's engineering judgment, expressed in that project's nouns.

An audit extracted **74 portable kernels** from those skills. **~29 (≈40%) are already
covered** by this plugin's gate + five skills — a good sign for both artifacts. **~54 are
genuinely new**, and they cluster into two themes:

- **integration / event semantics** — queues, webhooks, sync, retries
- **external control planes** — vendor APIs, credentials, deploy targets

**Neither cluster is covered by this plugin, nor by the `superpowers` plugin.** That is the
real gap this change closes.

## 2. Goals / non-goals

**Goals**
- Absorb the genuinely-new portable judgment without diluting adherence.
- Keep the core **universal** — the design rule (*"name no framework, no component, no
  colour"*) survives verbatim.
- Make the plugin **additionally valuable to anyone working in Go or lightweight-JVM
  backends**, extensibly (more languages later, with zero core churn).
- Preserve the existing authority ladder: **human > project (facts) > plugin (procedure)**.

**Non-goals**
- Generalising project-specific facts (a vendor console's API, host addresses, table names,
  a repo's helper signatures, its directory naming). Those are *correctly* local and stay
  where they are.
- Replacing `superpowers`. This plugin must work standalone and interoperate when
  superpowers is present.
- Rewriting the design rule to accommodate stack opinions.

## 3. The architectural insight

The naive framing is *"sharp doctrine vs complete doctrine."* That tradeoff is false,
because **adherence cost is not uniform**:

- **The gate is always-on.** Every line competes for attention on *every task, forever*.
- **Skills load by description.** A skill that fires only on integration work costs
  **nothing** on a CSS change.

Therefore: **take nearly all of it, and pay the cost where it is cheap.** The constraint is
not total rule count — it is **per-skill coherence** (one trigger, one job) and a **brutal
gate**.

This single observation drives every placement decision below.

## 4. Architecture — three layers

### Layer 1 — Universal core (names no language)
The gate + existing five skills + two new skills. Installs anywhere; useful to anyone.

### Layer 2 — Stack packs (description-gated, self-limiting)
Opinionated, **project-agnostic** setup guidance for a specific language/runtime. These are
safe to ship in a universal plugin **because skills load by description**: a skill described
*"Use when working in a Go backend service"* is *structurally incapable* of firing in a
Rails repo. That is a property of the loading mechanism, not a convention we must police.

Adding a language later = one new directory. **Zero core files change.**

### Layer 3 — Project-local (untouched, stays in the project)
Facts. A project's own skills keep knowing their own truths, and this plugin continues to
defer to them.

**The line between Layer 2 and Layer 3 is the one that matters:**

> A stack pack holds **how you would set up *any* service in that language.**
> A project skill holds **how *this* project's service is set up.**

Get that wrong and the pack leaks nouns — the exact failure the design rule exists to
prevent.

## 5. The bar (what earns a line)

Unchanged from the README, and applied to every rule below:

1. **Would this still be true in a project with a different stack, product, and team?**
   - Yes → core, nouns stripped.
   - Principle travels but the example doesn't → rewrite structurally.
   - No, but it's true for *every* project in this language → **stack pack**.
   - No → leave it in the project.
2. **Does it change what an agent does?** *"Reuse your primitives"* is advice.
   *"Reused twice → extract it"* is a standard. Only standards ship.
3. **One line, with teeth.** Wording is the product. A rule that reads as a suggestion will
   be treated as one.

## 6. Placement map

### 6.1 `core/GATE.md` — 4 edits only (always-on; keep brutal)
- **Sharpen Q2** from *"trace one concrete failure"* to **trace fail / duplicate / late** —
  a sharper instrument for any remote interaction.
- **Expand Q5's pattern list** with: *derived read-model, reconciler, echo guard,
  compensating action, contention-shaped lock.*
- **Resolve the ask-cadence contradiction** (see §9).
- Nothing else. Every other rule earns a skill or nowhere.

### 6.2 `skills/integration-instinct/` — NEW
Trigger: consuming or producing events, webhooks, queues, or syncing with a remote system.

- **Three consumer outcomes: success / retryable / poison.** A *business* "no" is a
  success — record the outcome and ack. Retrying a business failure forever is the queue
  death spiral.
- **Assume at-least-once *and unordered*.** Dedupe by the producer's event id with a TTL; a
  missing local row means fetch-then-insert, not error.
- **Enumerate what the producer does *not* emit.** Every un-evented mutation needs a
  polling reconciler. Push + reconcile, never push alone.
- **One kill-switch** every consumer path checks, flipped atomically the instant auth dies.
- **Disconnect ≠ delete.** Keep the foreign identity mapping so reconnect is resumption;
  clear only when the identity actually changes.
- **Echo guard** on bidirectional sync, or the system oscillates.
- **A job's identity is its inputs, not when it was scheduled.** A timestamp in the payload
  makes dedupe impossible.
- **Every retry needs a bound and a terminus.** Retry-forever with no dead-letter is data
  loss disguised as resilience.
- **Never assume producer boot order** — retry the attach with backoff. And never create the
  resource you only consume; that forks ownership.
- **An error you cannot fix by retrying must be acked and recorded**, not returned as
  failure — providers disable subscriptions that keep failing.

### 6.3 `skills/external-systems/` — NEW
Trigger: calling a vendor API, a control plane, a deploy target, or handling their
credentials.

- **Replace-vs-merge: determine which before calling any "save"/"update" API.** Assuming
  merge on a replace endpoint silently deletes everything you didn't send. Read-modify-write
  — and *read first*.
- **Find the immutable fields before creating a named external resource.** No rename
  endpoint means recreate + re-wire every reference.
- **An API that accepts a field and ignores it returns 200 and changes nothing.** Verify by
  read-back, not status code.
- **One refresher per refreshable credential**; everyone else fetches by RPC and caches
  under TTL minus a margin. Concurrent refresh = dogpile + revocation.
- **Inject expiring credentials as a provider function, not a value.** A value captured at
  construction is stale by definition.
- **Never copy a credential onto a dependent record**; reference the owning record.
- **Rate limits are per-vendor-account** → the limiter lives inside the client, keyed by
  that account. Detect tier from response headers; don't hardcode it.
- **Don't hardcode IDs from a vendor's default config** — resolve by semantic property at
  runtime and cache the resolution. Defaults vary per tenant.
- **A green build with a failed deploy is configuration, not code.** Changing code first
  destroys evidence and adds a variable.
- **Never hand-edit state that CI owns** — a manual edit is invisible drift. And with mutable
  tags, a new build is not a new deployment.
- **A cache of remote config needs a named invalidation event.** A TTL is not invalidation.
- **Never disable host-key verification to make a connection work.** Pin it.
- **Repeated auth failure is a signal to stop, not to retry.** A credential that stops
  working was more likely rotated than broken — retry loops escalate to a lockout you
  cannot undo.
- **Startup-time schema migration against a shared store makes deploy order a correctness
  variable.** Declare one owner, or make every participant additive + idempotent.

### 6.4 `skills/engineering-standards/` — absorbs the most (~22)
Two new sections plus extensions:

**New § Trust boundaries and tenancy**
- **Identity comes from the credential, never the payload.** At the edge, use a request type
  that *physically cannot express* the identity fields, rather than remembering to overwrite
  them.
- **Trust boundaries are asymmetric.** The same field is spoofable at the edge and
  authoritative behind it. Name where the boundary is.
- **Where tenants share a table, every query is scoped by the tenant key.** A missing scope
  is a *security incident*, not a bug. Tenancy identifiers pass through every hop unchanged.
- **Internal endpoints get their own path namespace and their own auth**; the public gateway
  must not route to them. The namespace makes the exposure audit greppable.

**New § Time semantics**
- **Separate instants from calendar semantics.** An instant is UTC; a day boundary, reset,
  or schedule is in the *user's* timezone. UTC for calendar semantics fails only for some
  users, on some days.

**§1 Fit the existing structure — extend**
- **Wiring is code in one place.** You should read the whole dependency graph in one file.
  No container, no annotation magic, no reflection.
- **One interface per axis of change, not per class.**
- **A gateway that forwards raw bytes and raw query strings is a tunnel, not a layer.** It
  owns unmarshalling, typing, and a service seam *even when the service is a pass-through* —
  the seam is where future logic lands.
- **A second language needs a capability justification, not a preference.** When you add
  one, map it 1:1 onto the existing layout and publish the mapping table — the cost of a new
  stack is navigational.
- **Mirror structure, not naming tics.** Drop a convention whose *reason* doesn't transfer
  to the host language.

**§2 Contract programming — extend**
- **Read the server's parsing code before writing the client.** Never write to an assumed
  contract; a shape mismatch is a runtime failure, not a compile error.
- **N-place agreement's failure signature is "looks healthy, doesn't work."** Enumerate the
  places in one doc.
- **If duplication is forced, name one copy canonical and declare drift a bug.** A vendored
  copy with no named source is a fork.
- **Tolerant reader, strict writer.** Ignore unknown inbound fields so a producer can add
  one without breaking you; omit nulls outbound.
- **One sanctioned path per class of change.** Two mechanisms managing the same objects must
  partition them explicitly; overlap is corruption.

**§3 Isolate the outside world — extend**
- **Never let the storage model leak into the API contract.** They change for different
  reasons.

**§4 Errors — extend**
- **Degrade deliberately and visibly, or fail loudly. Never silently.** A non-core upstream
  is an *optional* dependency: boot and render without it, degrading the metric — not the
  surface. *(Resolves the tension with the existing "a swallowed error that returns an empty
  list" rule: the difference is whether the degradation is declared.)*

**§5 Money, state, irreversible — extend**
- **Async after commit.** Snapshot inputs by value, start only after the transaction
  commits, always bound with a timeout.
- **An idempotent upsert on the natural key removes the need for a lock** — replica-safety
  becomes free.
- **Compensate explicitly, including any counter you consumed.** A rollback that forgets the
  quota is a slow leak.
- **A partial update must distinguish absent from set-to-zero.** A plain value type cannot,
  and you will silently blank fields.
- **Fail fast at boot on missing required config**; optional config gets an explicit default.
- **Pick the weakest background mechanism that meets the reliability bar** —
  fire-and-forget → in-process loop → durable queue + separate worker.
- **Name the concurrency primitive by contention shape** — contested row, work queue,
  once-per-cluster.
- **Every production mutation: open a transaction, SELECT the exact rows the predicate will
  hit, read them, then commit.** Never write a predicate you have not first run as a read.
  An ad-hoc query against a production table is a load event — bound it.
- **Constant-time compare for secrets and signatures.**
- **A security check that could break a live integration ships behind a per-env flag**, off
  until end-to-end is green.

### 6.5 `skills/verify-for-real/` — 1 high-value addition
- **A control plane's success field means "accepted," not "live."** Verify the resulting
  artifact's identity (digest/tag) and its timestamp. The system's own status field is not
  evidence.

### 6.6 `skills/git-discipline/` — 2 additions (new § Promotion)
- **A promotion merges everything on the source branch, not your change.** Enumerate the
  commit range before promoting — an integration branch accumulates other people's work.
- **If you committed to a protected branch locally, create the branch at HEAD *first*, then
  hard-reset.** The order is what saves the work.

### 6.7 `skills/ui-craft/` — unchanged
Zero UI content existed in the source corpus. No edit.

### 6.8 Stack packs — NEW
- `skills/go-service-shape/`
- `skills/java-service-shape/`

**Flat, not nested.** All three consumers discover skills one level deep — `install.sh`
globs `skills/*/`, and plugin skill discovery is flat. A `skills/stacks/<lang>/` layout would
be silently omitted from the Codex block and likely undiscovered elsewhere. The directory
was never the isolation mechanism anyway.

Contents: project-agnostic setup opinions only — no framework where a thin router will do;
constructor wiring in `main` with no container; env config read once at startup and passed
in; the fat-jar/worker shape for the JVM; idiom notes that only make sense per-language
(e.g. an `Impl` suffix that disambiguates a single implementation is noise where there are
three — adopt the host idiom when the original's *reason* doesn't transfer).

**Description contract (load-bearing — this is the entire isolation mechanism):** each
pack's `description` must name its language and runtime explicitly and lead with the
trigger, so it cannot fire elsewhere. E.g. *"Use when writing or restructuring a Go backend
service…"*.

**Naming convention:** `<language>-service-shape`. This is what the nouns check keys off
(§10) to permit language nouns in packs while forbidding them in the core.

**Extensibility:** a new language = one new `skills/<lang>-service-shape/` directory. No
core file changes. The README documents this as the contract.

## 7. Interop with `superpowers`

The plugin **works standalone and is sharper with superpowers installed.**

**Mechanism.** Skills are static markdown and cannot self-disable. The only surface with
runtime knowledge is the **gate injection** — which already exists in three thin adapters
reading one `GATE.md`:

- `hooks/session-start.sh` (Claude Code)
- `.opencode/plugins/senior-dephx.js` (OpenCode)
- `install.sh --codex` (Codex, resolved at install time)

Each detects whether superpowers is present and, if so, appends one routing line to the
injected gate:

> *superpowers is installed — for generic debugging use `superpowers:systematic-debugging`;
> for spec-shaped design use `superpowers:brainstorming`.*

Additionally, each overlapping skill carries a **static deference note** so it remains
correct even when detection fails or isn't available.

**Keep the non-overlapping halves unconditionally.** superpowers owns *generic* debugging
method; it does not carry the priors *"a green build with a failed deploy is configuration"*
or *"the orchestrator's status field is not evidence."* Those ship regardless.

README gains one honest paragraph stating: works alone; better together; who wins where.

## 8. What is explicitly NOT ported

- Every project-local fact: vendor console APIs, host addresses, table and column names,
  helper signatures, directory naming, credential locations. These stay in the project's own
  skills — the plugin already defers to them, and the audit's verdict was that they are *the
  right kind of local*.
- **`grill-me` is not ported.** ~75% of it is already in the gate, and its remaining novel
  half is covered by `superpowers:brainstorming`.

## 9. A live contradiction to fix

The source corpus's `grill-me` says *"ask one question at a time; batching is bewildering."*
This gate says *"One consolidated round, not a drip"* — and `software-engineer-intuition`
Step 4 repeats it. **These conflict**, and the conflict is live today.

**Resolution (into the gate, one line):**

> **Consolidated round for *independent* forks; one question at a time only when the answers
> are *dependent*** — i.e. when a later question's content changes based on an earlier
> answer (a design tree). Never a drip of independent questions.

## 10. Verification

The plugin preaches *"a build is not a verification"* and currently cannot verify itself.
This change closes that:

- **`test/smoke.sh`** — proves all three install paths still wire up after any change:
  1. Claude: `plugin.json` + `marketplace.json` parse; every `skills/**/SKILL.md` has valid
     frontmatter with a non-empty `name` + `description`; `hooks/hooks.json` parses and the
     hook is executable and emits the gate.
  2. OpenCode: the plugin module imports; `config()` appends the skills path; the transform
     injects exactly once and is idempotent on re-entry.
  3. Codex: `install.sh --codex --here` into a temp dir writes the block; **running it twice
     produces an identical file** (idempotence) and preserves surrounding content.
- **A nouns check** — grep `core/` and every `skills/*/` **except `*-service-shape/`** for a
  denylist of framework/vendor/language tokens. The design rule becomes *executable*, not
  aspirational. This is the highest-leverage test in the repo.
  - Packs are exempt from the *language* denylist (naming Go is their job) but **not** from
    the *project*-noun denylist — a pack that names a company's helper, table, or host has
    become a project skill wearing a language's name.

## 11. Rollout

1. Gate edits (4) + the cadence resolution.
2. `integration-instinct` + `external-systems` (the two gap-filling skills).
3. `engineering-standards` absorption (the bulk).
4. `verify-for-real` + `git-discipline` additions.
5. Stack packs + the extensibility contract in the README.
6. superpowers detection in the three adapters + static deference notes.
7. `test/smoke.sh` + the nouns check.
8. README: stack-pack paragraph, superpowers paragraph, version → 0.2.0.

Each step is independently reviewable. Steps 1–4 are pure doctrine; 5–8 are wiring.

## 12. Risks

- **Volume dilutes the gate.** Mitigated by the §3 insight: the gate takes only 4 edits;
  everything else lives behind a description.
- **A stack pack leaks project nouns** — it becomes "this project's setup" wearing a
  language's name. Mitigated by the §4 Layer-2/3 line and the nouns check (which must cover
  packs for *project* nouns while permitting *language* nouns).
- **Wording softens under volume.** 54 rules written quickly become advice. The §5 bar is the
  control; each rule ships as one line with teeth or doesn't ship.
- **superpowers detection is best-effort** across three tools. Mitigated by the static
  deference notes — correctness never depends on detection succeeding.
