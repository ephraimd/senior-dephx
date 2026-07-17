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
  # Strip the key, keep the rest verbatim: descriptions contain their own colons, so
  # splitting on ':' truncates them. (substr($0,index($0,$2)) looks equivalent but returns
  # the whole line when the value is empty, which makes the empty check unfireable.)
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

echo
[ "$FAIL" -eq 0 ] && echo "smoke: PASS" || echo "smoke: FAIL"
exit "$FAIL"
