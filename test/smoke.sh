#!/usr/bin/env bash
# The plugin preaches "a build is not a verification" and could not verify itself.
# This is that verification: it proves all three install paths still wire up, and that
# the design rule (no project/framework nouns in the core) actually holds.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

# The one way this suite reads a description — three checks need it, so it is a primitive,
# not a copied line. Strips the key and keeps the value verbatim: descriptions contain their
# own colons, so -F': *' truncates them, and substr($0,index($0,$2)) looks equivalent but
# returns the WHOLE line when the value is empty, which makes any empty check unfireable.
skill_desc() { awk '/^description:/{sub(/^description:[[:space:]]*/, ""); print; exit}' "$1"; }

echo "== manifests parse =="
# Without this guard a missing python3 reports "does not parse" against every manifest —
# a lie about the file. Blame the missing tool, not the JSON.
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 not found — cannot validate manifests"
else
  for f in "$ROOT/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/marketplace.json" "$ROOT/package.json"; do
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then pass "$(basename "$f")"; else fail "$(basename "$f") does not parse"; fi
  done
fi

echo "== every skill has usable frontmatter =="
for d in "$ROOT"/skills/*/; do
  s="$d/SKILL.md"; n="$(basename "$d")"
  [ -f "$s" ] || { fail "$n has no SKILL.md"; continue; }
  name="$(awk -F': *' '/^name:/{print $2; exit}' "$s")"
  desc="$(skill_desc "$s")"
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

echo "== nouns: the core names no framework/vendor (the design rule, executable) =="
# Two tiers, because one grep cannot serve both halves of this list.
# TIER1 has no ordinary-English meaning, so a case-insensitive word-boundary match is safe.
# TIER2 words are ALSO everyday English -- "cards go 1-col", "watch the test go red",
# "guard rails", "react to feedback", "express intent". Word boundaries only fix substring
# collisions (the "gin" inside "plugin"); they do nothing for a whole word that is simply
# English. So TIER2 matches the capitalised proper noun only where prose actually names a
# technology: mid-sentence after a lowercase word ("use Spring", "in Go"), or followed by a
# tech qualifier ("Go service"). Sentence-initial "Go and find out" stays clean.
# A noisy check gets ignored, and an ignored check is worse than none.
# MD_PUNCT lets the markdown dress the noun -- "use `Spring`", "use **Go**" -- which is how a
# doctrine file would most likely name one. Known gap: a sentence-initial mention followed by
# an arbitrary verb ("Spring handles that.") is NOT caught. Closing it needs an ^-anchored
# branch, which flags this repo's own imperative voice ("Go and find out", "Express intent"),
# and a check that cries wolf gets switched off. Grep cannot win that one; review must.
TIER1_NOUNS='golang|jvm|nestjs|django|laravel|gorm|postgres|postgresql|mysql|mongodb|redis|kafka|rabbitmq|nats|gradle|jquery|svelte'
TIER2_NOUNS='Go|Java|Spring|Node|Express|Rails|Flask|React|Vue|Gin|Echo|Fiber|Maven|Hibernate'
TIER2_QUALIFIER='service|app|application|component|module|framework|library|package|handler|router|controller|struct|project|backend|server'
MD_PUNCT='[`"'"'"'*_(]*'
PROJECT_NOUNS='revhero|dokploy|hubspot|pipedrive|safedbquery|respondok'
for d in "$ROOT"/core "$ROOT"/skills/*/; do
  n="$(basename "$d")"
  case "$n" in *-backend-blueprint) continue ;; esac   # blueprints may name their language/libs
  # Three greps, so test the captured text -- a group's exit status is only its LAST command's,
  # which would silently swallow a tier-1 hit.
  hits="$( { grep -rniE "\b($TIER1_NOUNS)\b" "$d"; \
             grep -rnE "[a-z][[:space:]]+$MD_PUNCT($TIER2_NOUNS)\b" "$d"; \
             grep -rnE "\b($TIER2_NOUNS)[\`\"'*_)]*[[:space:]]+($TIER2_QUALIFIER)\b" "$d"; } 2>/dev/null )"
  if [ -n "$hits" ]; then
    fail "$n names a framework/vendor:"; printf '%s\n' "$hits" | head -3 | sed 's/^/       /'
  else pass "$n is noun-free"; fi
done

echo "== nouns: NOTHING may name a company/product/repo/host — blueprints included =="
if hits="$(grep -rniE "\b($PROJECT_NOUNS)\b" "$ROOT"/core "$ROOT"/skills 2>/dev/null)"; then
  fail "project noun leaked:"; printf '%s\n' "$hits" | head -3 | sed 's/^/       /'
else pass "no project nouns anywhere"; fi

echo "== blueprints load ONLY on explicit request =="
# A blueprint is a personal house style. It is only safe to ship in a universal plugin
# because it loads when asked for BY NAME and never on its own; one that can auto-load
# imposes one person's taste on a stranger's repo. That rule lives in the description,
# so the description is what gets tested.
#
# install.sh renders the Codex block with "${desc:0:150}…". A gate clause past char 150
# is invisible to Codex — it would advertise the blueprint with the gate cut off. Truncate
# with install.sh's own idiom and keep it that way: anything that merely approximates it
# (`cut -c`, which counts bytes on some platforms and characters on others) drifts from the
# code it is modelling, and a check that models the code loosely stops testing the code.
#
# Two words are not a gate. "only" and "explicit" are ordinary English (and "commonly"
# contains "only"), so matching either one alone lets ungated prose through. Require the
# restriction AND the request it is conditioned on, in the same sentence.
# Known gap: this reads phrasing, not meaning. It proves the sentence is there, not that
# the body honours it — review must do that.
GATE_RESTRICT='\b(only|explicit(ly)?)\b[^.]*\b(ask(s|ed)?|request(s|ed)?|invoke[sd]?|name[sd]?|demand)\b'
GATE_NEGATION="(do not|don't|never|must not) (load|use|apply|auto-load)[^.]*(general|other)"
for d in "$ROOT"/skills/*-backend-blueprint/; do
  [ -d "$d" ] || continue   # no blueprints yet: the glob stays literal, and that is fine
  n="$(basename "$d")"; s="$d/SKILL.md"
  [ -f "$s" ] || { fail "$n has no SKILL.md"; continue; }
  desc="$(skill_desc "$s")"
  # Herestrings, not `printf | grep -q`: this file already learned that grep -q exits on
  # first match and SIGPIPEs the writer, which pipefail then reports as a failure.
  # if/else, not `grep && pass || fail`: a pass whose printf fails (smoke.sh piped into
  # head) falls straight through to fail and turns a clean repo red.
  if grep -qiE "$GATE_RESTRICT" <<<"${desc:0:150}"; then
    pass "$n gated within the first 150 chars"
  else
    fail "$n: gate clause missing from the first 150 chars of description (Codex truncates there)"
  fi
  if grep -qiE "$GATE_NEGATION" <<<"$desc"; then
    pass "$n states the do-not-autoload rule"
  else
    fail "$n: description must say it must NOT load for general work in the language"
  fi
done

echo
[ "$FAIL" -eq 0 ] && echo "smoke: PASS" || echo "smoke: FAIL"
exit "$FAIL"
