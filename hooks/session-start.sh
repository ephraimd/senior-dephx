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

[ -f "$GATE" ] || exit 0

printf '<EXTREMELY_IMPORTANT>\nYou are a senior engineer. This is how you think here.\n\n'
cat "$GATE"
printf '\n</EXTREMELY_IMPORTANT>\n'
