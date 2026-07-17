#!/usr/bin/env bash
# Injects the always-on gate at session start.
#
# The gate has to be present without being asked for; a thinking discipline that only
# applies when someone remembers to invoke it is not a discipline. The full procedure
# stays in the software-engineer-intuition skill and loads on demand - only the gate is
# resident.
#
# Matches startup|clear|compact so it survives a context compaction, which is exactly
# when an agent starts forgetting how the human wanted it to work.
set -euo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GATE="$ROOT/core/GATE.md"
SUPER="$ROOT/core/SUPERPOWERS.md"

[ -f "$GATE" ] || exit 0

# The sibling plugin sits at an unpredictable depth: a marketplace cache nests it under
# <marketplace>/superpowers/<version>/, a linked install sits one level down. So this
# searches for the directory instead of testing a fixed path, and the search roots are
# overridable so both branches are testable.
#
# Detection must NEVER fail the hook. A missing root, an unreadable one, or a search that
# matches nothing all mean "not installed", not "error". This runs under `set -e`, where a
# bare failing test kills the script and a dead hook emits no gate at all - a far worse
# outcome than a missing deference note. Hence: no bare globs (an unmatched one stays
# literal and would false-positive), every status either consumed by an `if` or defused.
superpowers_present() {
  local search="${SENIOR_DEPHX_PLUGIN_SEARCH:-${HOME:-}/.claude/plugins:$PWD/.claude/plugins}"
  local roots=() root hit
  # read -a, not `for root in $search`: unquoted expansion would also glob-expand a root
  # containing a wildcard. The herestring guarantees the trailing newline read wants.
  IFS=':' read -ra roots <<<"$search" || true
  for root in "${roots[@]+"${roots[@]}"}"; do
    if [ -z "$root" ] || [ ! -d "$root" ]; then continue; fi
    # No pipe to `head`: SIGPIPE plus pipefail would surface as a failed assignment.
    hit="$(find "$root" -maxdepth 4 -type d -name 'superpowers*' -print 2>/dev/null || true)"
    if [ -n "$hit" ]; then return 0; fi
  done
  return 1
}

printf '<EXTREMELY_IMPORTANT>\nYou are a senior engineer. This is how you think here.\n\n'
cat "$GATE"
if [ -f "$SUPER" ] && superpowers_present; then
  printf '\n'
  cat "$SUPER"
fi
printf '\n</EXTREMELY_IMPORTANT>\n'
