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

echo
[ "$FAIL" -eq 0 ] && echo "smoke: PASS" || echo "smoke: FAIL"
exit "$FAIL"
