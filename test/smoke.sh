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

echo "== hook defers to the sibling plugin only when it is installed =="
# BOTH branches, against a real search root. A detection test that only exercises the
# present-branch cannot tell "correctly silent" from "silently broken" - and the negative
# is the branch that carries the promise this plugin makes: it works alone.
# SENIOR_DEPHX_PLUGIN_SEARCH exists so this is testable without installing anything.
FRAGMENT='superpowers owns the procedure'
sp_yes="$(mktemp -d)"; mkdir -p "$sp_yes/superpowers"
sp_no="$(mktemp -d)"

# Capture, don't pipe - see the gate check above for why `grep -q` cannot be used here.
yes_out="$(CLAUDE_PLUGIN_ROOT="$ROOT" SENIOR_DEPHX_PLUGIN_SEARCH="$sp_yes" "$ROOT/hooks/session-start.sh" 2>/dev/null)"
case "$yes_out" in
  *"$FRAGMENT"*) pass "installed: hook emits the deference fragment" ;;
  *) fail "installed: hook did not emit the deference fragment" ;;
esac
case "$yes_out" in
  *"The Gate"*) pass "installed: the gate survives alongside the fragment" ;;
  *) fail "installed: the fragment displaced the gate" ;;
esac

# A root that does not exist is deliberately in the path: a missing dir must read as "not
# installed", never as an error. The hook runs under `set -e`, so this asserts the exit
# status too - a hook that dies emits no gate at all, which is the worst outcome here.
no_rc=0
no_out="$(CLAUDE_PLUGIN_ROOT="$ROOT" SENIOR_DEPHX_PLUGIN_SEARCH="$sp_no:$sp_no/absent" "$ROOT/hooks/session-start.sh" 2>/dev/null)" || no_rc=$?
case "$no_out" in
  *"$FRAGMENT"*) fail "absent: hook emitted the deference fragment with no sibling installed" ;;
  *) pass "absent: hook stays silent about the sibling" ;;
esac
case "$no_out" in
  *"The Gate"*) pass "absent: the gate is emitted anyway (the plugin stands alone)" ;;
  *) fail "absent: hook did not emit the gate" ;;
esac
if [ "$no_rc" -eq 0 ]; then pass "absent: hook exits 0"; else fail "absent: hook exited $no_rc"; fi
rm -rf "$sp_yes" "$sp_no"

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
# Companies, products, repositories, hosts. NOT the author's helper vocabulary: a blueprint
# exists to define names like RespondOK or SafeDBQuery so a fresh repo can build them, and
# banning them would stop the house style from naming itself. The rule the doctrine actually
# states is "never cite a helper as though it already exists somewhere" - that is a claim
# about context, which no grep can see. Review owns it; this list owns the proper nouns.
PROJECT_NOUNS='revhero|dokploy|hubspot|pipedrive'
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

echo "== the codex installer never damages a file it does not own =="
# install_codex is the ONLY installer path that writes to a file the user owns; the other
# two print instructions and touch nothing. So it is the only place install.sh can destroy
# work, and its promise -- replace our own block, disturb nothing else -- was untested.
# A second block on re-run, or a swallowed paragraph of someone's own notes, is the worst
# bug this repo could ship: it lands on a file the plugin does not own, via the one command
# users are invited to re-run on every upgrade.
codex_tmp="$(mktemp -d)"
# A trap, not a trailing `rm`: unlike the sibling-plugin check above, this block fails in
# the middle sometimes, and a failing assertion must not litter /tmp with AGENTS.md files.
trap 'rm -rf "$codex_tmp"' EXIT

# The markers are a wire format, not an implementation detail: they are already sitting in
# every file the installer has ever touched. Hardcode them rather than sourcing install.sh
# -- if someone edits them, the next install appends a SECOND block to every existing file
# instead of replacing, and this check going red is exactly the alarm that deserves.
CODEX_BEGIN='<!-- BEGIN senior-dephx -->'
CODEX_END='<!-- END senior-dephx -->'
CODEX_ANCHOR='# How I work'          # rendered inside the block, so it tracks the block
CODEX_CORRUPT='# CORRUPTED BY A HUMAN EDIT'

# Run the REAL installer as a subprocess. Never source it, never re-implement its awk here:
# a test that reimplements the code under test only ever proves the copy agrees with itself.
#   - cd inside a subshell, so the suite's own cwd survives.
#   - --here targets ./AGENTS.md, so $HOME is never consulted on this path. HOME is pointed
#     into the temp dir ANYWAY, belt and braces: the no-arg path does `mkdir -p $HOME/.codex`
#     and writes there, so if arg parsing ever shifts (or `${2:-}` stops seeing --here), the
#     blast radius is a stray file inside the dir we delete -- never the real ~/.codex.
codex_install() {
  local rc=0
  ( cd "$codex_tmp" && HOME="$codex_tmp/fake-home" bash "$ROOT/install.sh" --codex --here ) >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# Occurrences, not `grep -c`, which counts matching LINES: two markers landing on one line
# would read as a clean "1" and the duplicate-block check would pass while broken.
# `wc -l` pads its output on BSD, hence the tr.
count_str() { grep -oF "$1" "$2" | wc -l | tr -d '[:space:]'; }

# Byte-for-byte, not `grep 'is my line still there'`: the promise is that the user's bytes
# are untouched, and grep would nod along at a file that lost a blank line or gained an
# indent. install_codex only ever appends or splices its own block, so the seed stays a
# literal byte prefix and the trailing notes a literal byte suffix, across every run.
# `wc -c` pads on BSD and GNU head rejects a padded count, so strip before use.
byte_count() { wc -c < "$1" | tr -d '[:space:]'; }
prefix_is() { head -c "$(byte_count "$2")" "$1" | cmp -s - "$2"; }   # FILE EXPECTED
suffix_is() { tail -c "$(byte_count "$2")" "$1" | cmp -s - "$2"; }   # FILE EXPECTED

# Deliberately awkward bytes. `&` is sed's "the whole match" character and `\1` is a
# backreference: an implementation that reached for s/// instead of awk would corrupt these
# lines while every "did the block get written" check stayed green.
cat > "$codex_tmp/seed.md" <<'SEED'
# My own AGENTS.md

Notes the plugin does not own, with bytes chosen to hurt: a `backtick`, a $DOLLAR,
a "quote", a 'squote', a back\slash, an & ampersand, and a \1 backreference.

<!-- BEGIN my-own-thing -->
A marker-shaped comment that is NOT ours. It must survive untouched.
<!-- END my-own-thing -->
SEED

# Trailing content is exactly where a naive range-delete corrupts a file: delete-from-BEGIN-
# to-EOF is indistinguishable from delete-from-BEGIN-to-END until someone writes a line down
# here. It is also the case a hand-test skips, because a human appends their notes ABOVE the
# block, where they are already safe.
cat > "$codex_tmp/after.md" <<'AFTER'

## Notes I keep BELOW the plugin block

If a range-delete ran to EOF instead of to the END marker, this paragraph is what
disappears -- silently, on an upgrade, in a file the plugin does not own.
AFTER

cp "$codex_tmp/seed.md" "$codex_tmp/AGENTS.md"

# A fixture that came out empty would make every byte-for-byte check below pass while
# proving nothing: byte_count returns 0, `head -c 0` emits nothing, and cmp of two empty
# streams is "equal". BSD head additionally errors on -c 0 -- and that error is swallowed,
# so the vacuous pass is indistinguishable from a real one; GNU head accepts -c 0 and goes
# vacuous with no hint at all. This suite has already been bitten once by a check that
# looked right and could never fire. Assert the fixtures exist before trusting them.
if [ -s "$codex_tmp/seed.md" ] && [ -s "$codex_tmp/after.md" ]; then
  pass "fixtures: seed and trailing notes are non-empty"
else
  fail "fixtures: a heredoc came out empty — every byte-for-byte check below is vacuous"
fi

# 1. Fresh install into a file that already has the user's own content.
codex_rc=0; codex_install || codex_rc=$?
if [ "$codex_rc" -eq 0 ]; then pass "fresh: installer exits 0"; else fail "fresh: installer exited $codex_rc"; fi
nbegin="$(count_str "$CODEX_BEGIN" "$codex_tmp/AGENTS.md")"; nend="$(count_str "$CODEX_END" "$codex_tmp/AGENTS.md")"
if [ "$nbegin" = "1" ] && [ "$nend" = "1" ]; then pass "fresh: exactly one block written"; else fail "fresh: expected 1 BEGIN/1 END, got $nbegin/$nend"; fi
if [ "$(count_str "$CODEX_ANCHOR" "$codex_tmp/AGENTS.md")" = "1" ]; then pass "fresh: block carries the rendered doctrine"; else fail "fresh: block missing '$CODEX_ANCHOR'"; fi
if prefix_is "$codex_tmp/AGENTS.md" "$codex_tmp/seed.md"; then pass "fresh: pre-existing content survives byte for byte"; else fail "fresh: pre-existing content was altered"; fi

# Now the user adds notes BELOW our block, and only then do we re-run.
cat "$codex_tmp/after.md" >> "$codex_tmp/AGENTS.md"

# 2. Re-run is idempotent. The assertion that matters most: an installer that appends a
#    second block on every upgrade grows the file without bound and double-loads the gate.
codex_rc=0; codex_install || codex_rc=$?
if [ "$codex_rc" -eq 0 ]; then pass "re-run: installer exits 0"; else fail "re-run: installer exited $codex_rc"; fi
nbegin="$(count_str "$CODEX_BEGIN" "$codex_tmp/AGENTS.md")"; nend="$(count_str "$CODEX_END" "$codex_tmp/AGENTS.md")"
if [ "$nbegin" = "1" ] && [ "$nend" = "1" ]; then pass "re-run: still exactly one block (no duplicate appended)"; else fail "re-run: expected 1 BEGIN/1 END, got $nbegin/$nend"; fi
if [ "$(count_str "$CODEX_ANCHOR" "$codex_tmp/AGENTS.md")" = "1" ]; then pass "re-run: doctrine present exactly once"; else fail "re-run: '$CODEX_ANCHOR' appears $(count_str "$CODEX_ANCHOR" "$codex_tmp/AGENTS.md") times"; fi
if prefix_is "$codex_tmp/AGENTS.md" "$codex_tmp/seed.md"; then pass "re-run: content above the block survives byte for byte"; else fail "re-run: content above the block was altered"; fi
if suffix_is "$codex_tmp/AGENTS.md" "$codex_tmp/after.md"; then pass "re-run: content BELOW the END marker survives byte for byte"; else fail "re-run: content below the END marker was corrupted"; fi

# 3. Upgrade replaces the block's contents rather than duplicating them. Mutate a line
#    INSIDE the markers -- the shape of a stale block from an older version.
# Whole-line equality against the anchor constant, not sub(/literal/): a second copy of the
# anchor would drift from CODEX_ANCHOR, and sub()'s replacement expands `&` to the match.
# If the anchor ever stops matching, the guard below fires rather than passing vacuously.
awk -v a="$CODEX_ANCHOR" -v c="$CODEX_CORRUPT" '$0==a {$0=c} {print}' "$codex_tmp/AGENTS.md" > "$codex_tmp/mutated" \
  && mv "$codex_tmp/mutated" "$codex_tmp/AGENTS.md"
if [ "$(count_str "$CODEX_CORRUPT" "$codex_tmp/AGENTS.md")" = "1" ]; then
  pass "upgrade: setup mutated a line inside the markers"
else
  fail "upgrade: setup failed to mutate inside the markers — the next checks prove nothing"
fi
codex_rc=0; codex_install || codex_rc=$?
if [ "$codex_rc" -eq 0 ]; then pass "upgrade: installer exits 0"; else fail "upgrade: installer exited $codex_rc"; fi
if [ "$(count_str "$CODEX_CORRUPT" "$codex_tmp/AGENTS.md")" = "0" ]; then pass "upgrade: stale block content is gone"; else fail "upgrade: stale block content survived the re-render"; fi
if [ "$(count_str "$CODEX_ANCHOR" "$codex_tmp/AGENTS.md")" = "1" ]; then pass "upgrade: fresh doctrine restored, exactly once"; else fail "upgrade: '$CODEX_ANCHOR' appears $(count_str "$CODEX_ANCHOR" "$codex_tmp/AGENTS.md") times"; fi
nbegin="$(count_str "$CODEX_BEGIN" "$codex_tmp/AGENTS.md")"; nend="$(count_str "$CODEX_END" "$codex_tmp/AGENTS.md")"
if [ "$nbegin" = "1" ] && [ "$nend" = "1" ]; then pass "upgrade: replaced, not duplicated"; else fail "upgrade: expected 1 BEGIN/1 END, got $nbegin/$nend"; fi
if prefix_is "$codex_tmp/AGENTS.md" "$codex_tmp/seed.md"; then pass "upgrade: content above the block survives byte for byte"; else fail "upgrade: content above the block was altered"; fi
if suffix_is "$codex_tmp/AGENTS.md" "$codex_tmp/after.md"; then pass "upgrade: content BELOW the END marker survives byte for byte"; else fail "upgrade: content below the END marker was corrupted"; fi

# The real ~/.codex is what this suite must never touch. --here plus the HOME override make
# that impossible; assert it rather than trust it. Proven by mutation: an installer patched
# to ignore --here lands in the temp fake-home and turns this line red, with the user's own
# ~/.codex untouched.
if [ ! -e "$codex_tmp/fake-home" ]; then pass "installer never reached for \$HOME"; else fail "installer wrote under \$HOME — the --here path is consulting it"; fi

rm -rf "$codex_tmp"; trap - EXIT

echo
[ "$FAIL" -eq 0 ] && echo "smoke: PASS" || echo "smoke: FAIL"
exit "$FAIL"
