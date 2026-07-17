# Portable Judgment Port — Implementation Plan (v0.2.0)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Use `superpowers:writing-skills` when authoring any `SKILL.md` — the frontmatter `description` is the trigger contract and is where most skills live or die.

**Goal:** Ship v0.2.0 — a universal `backend-shape` philosophy, an explicit-invocation-only `go-backend-blueprint`, five wrong-default rules, one gate fix, and the repo's first self-verification.

**Architecture:** Three tiers by *how they load*. The gate is always-on (1 edit, stays brutal). `backend-shape` auto-loads by description (universal, names no language). `go-backend-blueprint` loads **only on explicit request by name** — which is what lets it be totally opinionated, and what authorises it to override "fit the existing structure" in refactor mode. A `test/smoke.sh` harness makes the design rule executable.

**Tech Stack:** Markdown doctrine + bash. No compiler, no unit tests — **verification is the smoke test, the nouns check, and the gating check.**

**Dependency note:** the manifest checks shell out to `python3`. Every check that appends to
`test/smoke.sh` must not assume more than bash + coreutils + `python3`; if `python3` is
absent the manifest checks must say so plainly rather than report "does not parse", which
would be a lie about the file.

**Spec:** `docs/2026-07-02-portable-judgment-port-design.md`. **Branch:** `feat/portable-judgment-port`.

---

## Ordering note (deviation from the spec's §9)

The spec lists verification 6th. **This plan builds it 1st.** Every skill that lands afterwards is then guarded on arrival, and each check is proven to fail before it passes — which is what `verify-for-real` demands of everyone else. Shipping the checks last would mean writing the content unguarded and validating it once, at the end, which is the thing this repo exists to argue against.

## File structure

| File | Responsibility |
|---|---|
| `test/smoke.sh` | **New.** The only verification. Manifests + frontmatter + hook + OpenCode module + Codex idempotence + nouns + blueprint gating. One file: it's one job (prove an install still works) and it's read top-to-bottom. |
| `core/GATE.md` | **Modify.** One edit: ask-cadence. |
| `skills/backend-shape/SKILL.md` | **New.** Universal shape philosophy. Auto-loads. Names no language. |
| `skills/go-backend-blueprint/SKILL.md` | **New.** Index + gate + modes + the standard's spine. Explicit-only. |
| `skills/go-backend-blueprint/references/*.md` | **New.** The concrete patterns. Split because one file would be unreadable; **this is a new convention in this repo, introduced for the blueprint alone.** |
| `skills/engineering-standards/SKILL.md` | **Modify.** 3 wrong-default rules. |
| `skills/verify-for-real/SKILL.md` | **Modify.** 2 wrong-default rules. |
| `hooks/session-start.sh`, `.opencode/plugins/senior-dephx.js`, `install.sh` | **Modify.** superpowers detection → one routing line. |
| `README.md`, `.claude-plugin/plugin.json`, `package.json` | **Modify.** Blueprints, superpowers, extensibility contract, 0.2.0. |

---

# Phase 0 — The harness (build it first, so everything after is guarded)

### Task 1: Smoke test — manifests, frontmatter, hook

**Files:** Create `test/smoke.sh`

- [ ] **Step 1: Write the check**

```bash
#!/usr/bin/env bash
# The plugin preaches "a build is not a verification" and could not verify itself.
# This is that verification: it proves all three install paths still wire up, and that
# the design rule (no project/framework nouns in the core) actually holds.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

echo "== manifests parse =="
for f in "$ROOT/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/marketplace.json" "$ROOT/package.json"; do
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then pass "$(basename "$f")"; else fail "$(basename "$f") does not parse"; fi
done

echo "== every skill has usable frontmatter =="
for d in "$ROOT"/skills/*/; do
  s="$d/SKILL.md"; n="$(basename "$d")"
  [ -f "$s" ] || { fail "$n has no SKILL.md"; continue; }
  name="$(awk -F': *' '/^name:/{print $2; exit}' "$s")"
  # Strip the key, keep the rest verbatim: descriptions contain their own colons, so
  # splitting on ':' truncates them. (substr($0,index($0,$2)) looks equivalent but returns
  # the WHOLE line when the value is empty — index($0,"") is 1 — which makes the empty
  # check unfireable. That bug shipped in the first draft of this plan and was caught only
  # by running the mutation in Step 3. This is why Step 3 exists.)
  desc="$(awk '/^description:/{sub(/^description:[[:space:]]*/, ""); print; exit}' "$s")"
  [ -n "$name" ] || fail "$n: empty name"
  [ -n "$desc" ] || fail "$n: empty description"
  [ -n "$name" ] && [ -n "$desc" ] && pass "$n frontmatter"
done

echo "== hook is executable and emits the gate =="
if [ -x "$ROOT/hooks/session-start.sh" ]; then pass "hook executable"; else fail "hook not executable"; fi
# Capture, don't pipe. `grep -q` exits on first match and SIGPIPEs the hook mid-write; the
# hook's own `set -e` turns that into exit 141, and pipefail here would report a false
# failure for a hook that emitted the gate perfectly well.
hook_out="$(CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/hooks/session-start.sh" 2>/dev/null)"
case "$hook_out" in
  *"The Gate"*) pass "hook emits gate" ;;
  *) fail "hook did not emit the gate" ;;
esac

echo
[ "$FAIL" -eq 0 ] && echo "smoke: PASS" || echo "smoke: FAIL"
exit "$FAIL"
```

- [ ] **Step 2: Make it executable and prove it PASSES on the repo as it stands**

Run: `chmod +x test/smoke.sh && ./test/smoke.sh`
Expected: `smoke: PASS` — every existing skill listed `ok`.

- [ ] **Step 3: Prove it actually fails (a check that cannot fail is decoration)**

Run:
```bash
cp skills/ui-craft/SKILL.md /tmp/uc.bak
sed -i '' 's/^description: .*/description:/' skills/ui-craft/SKILL.md
./test/smoke.sh; echo "exit=$?"
cp /tmp/uc.bak skills/ui-craft/SKILL.md
```
Expected: `FAIL ui-craft: empty description`, `exit=1`. Then restore → `smoke: PASS`.

- [ ] **Step 4: Commit**

```bash
git add test/smoke.sh
git commit -m "test: smoke — manifests, frontmatter, hook"
```

### Task 2: Nouns check — make the design rule executable

**Files:** Modify `test/smoke.sh`

- [ ] **Step 1: Append the check** (before the final summary block)

**SHIPPED — see `test/smoke.sh` for the authoritative version.** Do not paste a copy here;
two copies of a check drift, which is the failure this repo exists to end.

**The first draft of this step was wrong, and the lesson is load-bearing.** It used a single
case-insensitive denylist containing `go|java|spring|node|react|rails|express|echo|fiber|maven`.
**Those are English words.** Word boundaries fix *substring* collisions (`gin` inside
"plugin"); they do nothing for `go` the verb versus `Go` the language. Pasted verbatim it
failed instantly on this repo's own prose — *"**Go** and find out"*, *"cards **go** 1-col"*.

**What shipped instead — two tiers:**
- **Tier 1** — nouns with no English meaning (`golang|jvm|django|gorm|postgres|kafka|…`):
  matched case-insensitively. Unambiguous.
- **Tier 2** — nouns that are also English words: matched only as a **capitalised proper noun
  in a technology context** — mid-sentence after a lowercase word (`use Spring`, `in Go`), or
  before a tech qualifier (`Go service`). Also matched inside markdown code spans, since a
  backticked `` `Spring` `` is the most likely way a doctrine file names a framework.

**Known, accepted limitation (documented in-file):** a **sentence-initial** mention with an
arbitrary verb — `Spring handles that.` — is **not caught**, and cannot be by grep: closing it
needs `^`-anchoring, which flags this repo's own imperative voice, and the set of verbs
following a proper noun is unbounded. A third branch would make the check *look* complete.
**Grep loses that case; review must catch it.** Say so rather than implying full coverage.

- [ ] **Step 2: Run — expect PASS on the current core**

Run: `./test/smoke.sh`
Expected: every existing skill `ok ... is noun-free`, `ok no project nouns anywhere`, `smoke: PASS`.

- [ ] **Step 3: Prove it catches a planted noun**

Run:
```bash
echo "Always use Spring for this." >> skills/engineering-standards/SKILL.md
./test/smoke.sh; echo "exit=$?"
git checkout skills/engineering-standards/SKILL.md
```
Expected: `FAIL engineering-standards names a framework/vendor:` and `exit=1`. Then restore → PASS.

- [ ] **Step 4: Commit**

```bash
git add test/smoke.sh
git commit -m "test: nouns check — the design rule, executable"
```

### Task 3: Blueprint-gating check — a blueprint that can auto-load is a bug

**Files:** Modify `test/smoke.sh`

- [ ] **Step 1: Extract `skill_desc()` first, then append the check**

**SHIPPED — see `test/smoke.sh` for the authoritative version.** Not copied here: two copies
of a check drift.

Description-extraction is needed in three places, so it is a shell function
(`skill_desc`) — *"reused twice → extract it"*, applied to this repo's own test.

**The first draft of this step had four defects. All four are instructive:**
1. **`grep -qiE "only|explicit"` had no word boundary** — `only` matches inside
   **"c*only*"**… i.e. *"covers **commonly** used patterns"* would be certified as **gated**.
   That is a **false PASS on the gate**, which ships the catastrophe. It is the same
   substring bug the nouns check documents, reintroduced one section later.
2. **Two words are not a gate.** A lone "only" proves nothing (*"covering only composition"*).
   The shipped check requires the **restriction and the request it's conditioned on in the
   same sentence** — deliberately *tighter*: a false FAIL just makes the author reword; a
   false PASS imposes a house style on a stranger.
3. **`&& pass || fail` falls through.** If `pass`'s printf fails (stdout closed, e.g.
   `smoke.sh | head -1`), the `||` branch fires **too** — printing both `ok` and `FAIL` and
   turning a clean repo red. Use `if/else`.
4. **`cut -c1-150` didn't model `install.sh`**, which truncates with `${desc:0:150}` (`cut -c`
   counts bytes on some platforms, characters on others). Mirror the code you are testing.

**Rule this establishes:** on a gate, bias to false-FAIL. A false fail costs a reword; a
false pass costs the thing the gate exists to prevent.

- [ ] **Step 2: Run — passes vacuously (no blueprints yet), which is correct**

Run: `./test/smoke.sh`
Expected: `smoke: PASS`. The check has nothing to inspect until Task 7 — that's the point: it's armed *before* the blueprint exists.

- [ ] **Step 3: Commit**

```bash
git add test/smoke.sh
git commit -m "test: blueprint gating — an auto-loadable blueprint is a bug"
```

---

# Phase 1 — Doctrine (small, surgical)

### Task 4: Gate — resolve the ask-cadence contradiction

**Files:** Modify `core/GATE.md` (the "Ask on the forks" section)

- [ ] **Step 1: Replace the cadence sentence**

Find: `One consolidated round, not a drip.`

Replace with:

```markdown
One consolidated round for **independent** forks — never a drip. Ask one at a time only
when the answers are **dependent**: when a later question's content changes based on an
earlier answer (a design tree). Independence decides the cadence, not politeness.
```

- [ ] **Step 2: Mirror it in the skill so the two cannot drift**

In `skills/software-engineer-intuition/SKILL.md` Step 4, find `One consolidated round beats a drip of questions.` and replace with:

```markdown
One consolidated round for **independent** forks; one at a time only when answers are
**dependent** (a design tree). Never a drip of independent questions.
```

- [ ] **Step 3: Verify**

Run: `./test/smoke.sh && grep -rn "consolidated round" core/ skills/software-engineer-intuition/`
Expected: `smoke: PASS`; both files state the dependent/independent rule; no file still says only "not a drip".

- [ ] **Step 4: Commit**

```bash
git add core/GATE.md skills/software-engineer-intuition/SKILL.md
git commit -m "fix: resolve the ask-cadence contradiction (independent vs dependent forks)"
```

### Task 5: The five wrong-default rules

**Files:** Modify `skills/engineering-standards/SKILL.md`, `skills/verify-for-real/SKILL.md`

- [ ] **Step 1: Add three rules to `engineering-standards`**

Into **§3 Isolate the outside world**, append:

```markdown
- **Determine replace-vs-merge before any external save.** An "update" endpoint that
  *replaces* silently deletes everything you did not send. Read the current state, modify
  it, write it back whole — and read first. Assuming merge is the default failure here.
- **Enumerate what a provider does not emit.** Event coverage is never complete. Every
  mutation the provider does not tell you about needs a poll to find it. Push plus
  reconcile; push alone loses data quietly.
```

Into **§4 Validate at the edge, decide in the middle**, append:

```markdown
- **A business "no" is a success.** Three outcomes exist: success, retryable failure, and
  poison. "The card was declined" is a *result* — record it and acknowledge the message.
  Retrying a business failure until it succeeds is a loop that never ends.
```

- [ ] **Step 2: Add two rules to `verify-for-real`** (into "What to actually do")

```markdown
8. **Do not trust a control plane's own success field.** "Accepted" is not "live". Read the
   resulting artifact back — its identity (digest, tag, version) and its timestamp — and
   confirm it is the thing you just shipped. An API that accepts a field and ignores it
   still returns 200.
9. **A green build with a failed deploy is configuration, not code.** Changing code first
   destroys the evidence and adds a variable to a system that already has too many. Read the
   config, the env, and the wiring before you touch a line.
```

- [ ] **Step 3: Verify no noun leaked in**

Run: `./test/smoke.sh`
Expected: `smoke: PASS` — in particular `ok engineering-standards is noun-free` and `ok verify-for-real is noun-free`.

- [ ] **Step 4: Commit**

```bash
git add skills/engineering-standards/SKILL.md skills/verify-for-real/SKILL.md
git commit -m "feat: five rules where the model's default is actively wrong"
```

---

# Phase 2 — The universal skill

### Task 6: `backend-shape`

**Files:** Create `skills/backend-shape/SKILL.md`

- [ ] **Step 1: Write the frontmatter** (the trigger contract — get this right first)

```yaml
---
name: backend-shape
description: Use when designing or bootstrapping a backend service, or deciding where code lives - a new service, a new resource/feature, a new layer, or a project whose structure has no clear answer yet. Covers where wiring lives, organising by feature rather than layer, layer discipline, boundary DTOs, config at startup, and interface seams. In an existing codebase its structure wins - this is for when the shape is genuinely your call.
---
```

- [ ] **Step 2: Write the body — the rules are fixed by spec §5.1; the prose is craft**

Required sections, in order:
1. **The rule** — *the composition is readable in one place*. A DI container is fine; wiring you have to grep for is not. State it as the spine everything else hangs from.
2. **Deference (must come early, before any prescription):** in an existing codebase its shape wins — `engineering-standards` §1 outranks this skill. This fires only when the choice is genuinely yours. **Without this the skill reads as "restructure their repo," which would violate the plugin's own doctrine on install.**
3. **Organise by feature, not by layer** — a feature owns transport + decisions + data together; layer-folders scatter one change across three directories and hide a feature's blast radius.
4. **Each layer does only its job** — transport parses/validates/delegates and decides nothing; logic decides and knows no transport; data queries and holds no policy.
5. **Typed DTOs at every boundary; never the storage model on the wire** — they change for different reasons; couple them and a column rename is an API break.
6. **A framework is a decision to surface, not a default** — reach for the smallest thing that does the job, then wire it legibly.
7. **Config is read once, at startup, into a typed value** — required missing crashes at boot; optional gets an explicit default; never read the environment from inside a call path.
8. **One interface per axis of change, not per class.**
9. **Red flags table** — matching the house style of the other skills (`You catch yourself… | It means`). At minimum: *can't name where the app is wired* → the composition isn't in one place; *a new top-level folder per technical layer* → organising by layer; *a storage struct in a response* → boundary leak; *env read inside a handler* → config isn't at startup.

**Bar:** no language, no framework, no library may be named — the nouns check enforces this. Every rule is one line with teeth; a preference stated softly reads as a suggestion and changes nothing.

- [ ] **Step 3: Verify**

Run: `./test/smoke.sh`
Expected: `ok backend-shape frontmatter`, `ok backend-shape is noun-free`, `smoke: PASS`.

- [ ] **Step 4: Commit**

```bash
git add skills/backend-shape/
git commit -m "feat: backend-shape - the composition is readable in one place"
```

---

# Phase 3 — The blueprint (the big one)

### Task 7: `go-backend-blueprint` — SKILL.md (index + gate + modes)

**Files:** Create `skills/go-backend-blueprint/SKILL.md`

- [ ] **Step 1: Write the frontmatter — the gate clause MUST be inside the first 150 chars**

`install.sh` truncates at 150 for the Codex block. If the clause falls outside it, Codex advertises the blueprint with its gate cut off. Lead with the gate:

```yaml
---
name: go-backend-blueprint
description: ONLY when explicitly asked for the senior-dephx opinionated Go backend standard by name - do not load for general Go work (use backend-shape). An opinionated, complete house style for a Go backend service: composition root, graceful shutdown, the unified background-worker pattern, routing and middleware, config and dependency setup, data-layer and transaction discipline, the unified response envelope, pagination, and inter-service contracts. Two modes - build a new service to this standard, or fully refactor an existing one to it. Invoking it is the decision to adopt it.
---
```

Verify the gate survives truncation:
```bash
awk -F': *' '/^description:/{print substr($0, index($0,$2)); exit}' skills/go-backend-blueprint/SKILL.md | cut -c1-150
```
Expected: the visible text still contains "ONLY when explicitly asked" **and** "do not load for general Go work".

- [ ] **Step 2: Write the SKILL.md body — index, not content**

Required sections:
1. **What this is** — one opinionated house style. Not universal, not the only good answer, and not to be applied unasked.
2. **Two modes:** *greenfield* (build to this standard) and *full refactor* (bring an existing project to it).
3. **The authority note (load-bearing):** this skill **overrides** `backend-shape`'s deference and `engineering-standards` §1 *"fit the existing structure"* — because **invoking it by name is the human asking**, and the human outranks the default. That is the entire reason it must never auto-load.
4. **Refactor discipline:** even when invoked, **surface the scope before restructuring** — which resources, which layers, in what order, and what stays. A blueprint is not a licence to rewrite a repo in one pass.
5. **The spine** — the non-negotiables in one screen (composition root; feature folders; layers; typed DTOs; one response envelope; every list paginated; config at boot; graceful shutdown; workers use the unified pattern).
6. **Index of references**, each with its path and one line on when to read it.

- [ ] **Step 3: Verify the gating check now has something to bite on**

Run: `./test/smoke.sh`
Expected: `ok go-backend-blueprint gated within the first 150 chars`, `ok go-backend-blueprint states the do-not-autoload rule`, `smoke: PASS`.

- [ ] **Step 4: Prove the gating check fails without the clause**

Run:
```bash
cp skills/go-backend-blueprint/SKILL.md /tmp/bp.bak
sed -i '' 's/^description: ONLY when explicitly asked/description: Use when writing Go/' skills/go-backend-blueprint/SKILL.md
./test/smoke.sh; echo "exit=$?"
cp /tmp/bp.bak skills/go-backend-blueprint/SKILL.md
```
Expected: `FAIL go-backend-blueprint: gate clause missing…`, `exit=1`. Restore → PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/go-backend-blueprint/
git commit -m "feat: go-backend-blueprint - explicit-invocation-only house style"
```

### Tasks 8–12: The reference files

Each is one file, one job, and each must be **buildable from the document alone** — a fresh repo constructs these; nothing may be referenced as if it already exists. Canonical helper names ship **by name** (they are the house style). No company, product, repo, or host, ever — the nouns check enforces the second half.

**After each task:** run `./test/smoke.sh` (expect `smoke: PASS`) and commit `git add skills/go-backend-blueprint/references/<file> && git commit -m "docs(blueprint): <topic>"`.

- [ ] **Task 8 — `references/composition-and-lifecycle.md`**
  `main` as composition root: read config → build dependencies in dependency order → wire → serve. The whole graph readable in one function. Then **graceful shutdown**: signal handling, stop accepting new work, drain in-flight with a bounded deadline, tear down in reverse construction order, and the rule that every constructed resource has exactly one owner responsible for closing it. Include the failure this prevents: a worker or pool that outlives the process it belonged to.

- [ ] **Task 9 — `references/background-work.md`**
  The **unified worker pattern**: one shape every background job conforms to. Choosing the weakest mechanism that meets the reliability bar (fire-and-forget → in-process loop → durable queue + separate worker). Bounded retries with a terminus (dead-letter), deterministic job payloads (identity is the inputs, never the schedule time, or dedupe is impossible), start-after-commit with inputs snapshotted by value and a timeout, and once-per-cluster scheduling when replicas exist.

- [ ] **Task 10 — `references/http-layer.md`**
  Routing and middleware layout; the handler's job (parse → validate → delegate; no decisions); **the unified response envelope** (one success shape, one error shape, named and defined once); **pagination** on every list endpoint through a single executor — no endpoint invents its own paging; identity taken from the credential and never the payload, with an edge request type that cannot express identity fields at all.

- [ ] **Task 11 — `references/data-layer.md`**
  Where queries live; the **panic → domain error boundary** wrapped once so the data layer can never surface a stack trace to a caller; transaction discipline (the decision is re-read inside the transaction; a check outside it is not a guard); idempotent upsert on the natural key where it removes the need for a lock; migrations owned by one mechanism; connection-pool settings as an explicit deployment decision rather than a default.

- [ ] **Task 12 — `references/inter-service.md`**
  Contracts defined once and shared; **read the peer's parsing code before writing a client** (a shape mismatch is a runtime failure, not a compile error); typed clients, never a generic proxy or raw bytes; tenancy identifiers passed through every hop unchanged and never re-derived; the vendor boundary (one place to change, one place to read); credentials injected as a provider function, not a captured value.

---

# Phase 4 — Wiring and release

### Task 13: superpowers detection + static deference

**Files:** Modify `hooks/session-start.sh`, `.opencode/plugins/senior-dephx.js`, `install.sh`

- [ ] **Step 1: Detect in the Claude hook** — after the gate is printed, append:

```bash
# Detection is best-effort and correctness never depends on it: the static notes in the
# skills keep this correct when detection misses. This only sharpens routing.
if ls -d "$HOME"/.claude/plugins/*/superpowers >/dev/null 2>&1 \
   || ls -d "$HOME"/.claude/skills/systematic-debugging >/dev/null 2>&1; then
  printf '\n**superpowers is installed** — for generic debugging use `superpowers:systematic-debugging`; for spec-shaped design use `superpowers:brainstorming`. This plugin still wins on procedure.\n'
fi
```

- [ ] **Step 2: Same routing line in the OpenCode plugin** — inside `gate()`, append the identical sentence when `fs.existsSync(path.join(os.homedir(), '.config/opencode/skills/systematic-debugging'))`. Keep the read-once caching; do not add a per-step `fs` call.

- [ ] **Step 3: Static deference notes** — in `verify-for-real`, add one line: *"If `superpowers:verification-before-completion` is available, it covers the generic method; what follows is the part it does not carry — do not trust a system's own status report."* This keeps the skill correct with **or** without detection.

- [ ] **Step 4: Verify** — `./test/smoke.sh` (expect `ok hook emits gate`, `smoke: PASS`), and `CLAUDE_PLUGIN_ROOT=$PWD ./hooks/session-start.sh | tail -3` to see the routing line appear or not, matching reality on this machine.

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh .opencode/plugins/senior-dephx.js skills/verify-for-real/SKILL.md
git commit -m "feat: route to superpowers when present; static deference when not"
```

### Task 14: Codex idempotence check

**Files:** Modify `test/smoke.sh`

- [ ] **Step 1: Append**

```bash
echo "== codex install is idempotent and preserves surrounding content =="
TMP="$(mktemp -d)"; ( cd "$TMP" && printf 'MY OWN NOTES\n' > AGENTS.md \
  && "$ROOT/install.sh" --codex --here >/dev/null 2>&1 && cp AGENTS.md a1 \
  && "$ROOT/install.sh" --codex --here >/dev/null 2>&1 && cp AGENTS.md a2 )
if diff -q "$TMP/a1" "$TMP/a2" >/dev/null 2>&1; then pass "codex block is idempotent"; else fail "codex block changed on re-run"; fi
grep -q "MY OWN NOTES" "$TMP/a2" && pass "codex preserved existing content" || fail "codex clobbered existing content"
rm -rf "$TMP"
```

- [ ] **Step 2: Run** — `./test/smoke.sh`. Expected: both `ok`, `smoke: PASS`. *If it fails, that is a real bug in `install.sh`, not in the test — fix `install.sh`.*

- [ ] **Step 3: Commit**

```bash
git add test/smoke.sh
git commit -m "test: codex install idempotence"
```

### Task 15: README + version

**Files:** Modify `README.md`, `.claude-plugin/plugin.json`, `package.json`

- [ ] **Step 1: README — "What's in it" table** gains `backend-shape` (fires on backend shape decisions) and `go-backend-blueprint` (**explicit request only**).

- [ ] **Step 2: README — new section "Blueprints"**, stating: they are one person's house style, deliberately opinionated, **load only when asked for by name**, and exist because a house style applied unasked is the exact slop this plugin prevents. Include the **extensibility contract**: a new language is one `skills/<language>-backend-blueprint/` directory and **zero core changes**.

- [ ] **Step 3: README — new section "With superpowers"**: works alone; sharper together; superpowers owns generic debugging and spec-shaped design, this plugin owns procedure and house style; **nothing here depends on it being installed.**

- [ ] **Step 4: README — extend "The design rule"** with one line: the rule is now **executable** — `test/smoke.sh` fails if the core names a framework, and blueprints may name their language but never a company, product, repo, or host.

- [ ] **Step 5: Bump** `version` to `0.2.0` in `.claude-plugin/plugin.json` and `package.json`.

- [ ] **Step 6: Verify** — `./test/smoke.sh` (expect `smoke: PASS`, manifests still parse) and `grep -c '0.2.0' .claude-plugin/plugin.json package.json` → `1` each.

- [ ] **Step 7: Commit**

```bash
git add README.md .claude-plugin/plugin.json package.json
git commit -m "docs: blueprints, superpowers interop, executable design rule; v0.2.0"
```

### Task 16: Final verification

- [ ] **Step 1:** `./test/smoke.sh` → `smoke: PASS`, no `FAIL` lines.
- [ ] **Step 2:** `./install.sh --codex --here` in a temp dir; read the rendered block and confirm **the blueprint's line still shows its gate** after the 150-char truncation.
- [ ] **Step 3:** `node -e "import('./.opencode/plugins/senior-dephx.js').then(m=>console.log(typeof m.default))"` → `function`.
- [ ] **Step 4:** `git log --oneline main..HEAD` — one commit per task, nothing stray.
- [ ] **Step 5:** Then use `superpowers:finishing-a-development-branch`.

---

## Self-review against the spec

- **§3 filter** → Task 5 ships only wrong-defaults; no "facts" tasks exist. ✓
- **§4 soul** → Task 6 §1 is the spine; no framework prohibition anywhere; nouns check (Task 2) enforces it mechanically. ✓
- **§5.1 backend-shape** → Task 6, incl. the deference clause as an early, mandatory section. ✓
- **§5.2 blueprint** → Tasks 7–12; both modes, authority note, refactor scope discipline, concreteness bar, gate-in-first-150-chars (Task 7 Step 1) + its check (Task 3). ✓
- **§5.3 five rules** → Task 5. ✓
- **§5.4 gate** → Task 4, mirrored into the skill so the two cannot drift. ✓
- **§5.5 verification** → Tasks 1–3, 14; each check proven to fail before it passes. ✓
- **§5.6 README/version** → Task 15. ✓
- **§6 flat layout** → all skills at `skills/<name>/`; `references/` nests *inside* the blueprint only, which `install.sh`'s `skills/*/` glob still reads correctly (it reads `SKILL.md`, not the tree). ✓
- **§7 superpowers** → Task 13, with static deference so correctness never depends on detection. ✓
- **Placeholders:** none — every check is complete bash; every prose file has a fixed section contract and its rules are fixed by spec §5.1/§5.2. The prose itself is authored at execution via `writing-skills`, which is craft, not a placeholder.
- **Naming consistency:** `go-backend-blueprint` and `*-backend-blueprint` are used identically in Tasks 3, 7, 8–12, 15, and the nouns-check exemption. ✓
