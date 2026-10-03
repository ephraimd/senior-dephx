#!/usr/bin/env bash
#
# senior-dephx installer.
#
# Wires the same doctrine into all three tools from one source. Each tool gets the shape
# it actually supports rather than a pretend-uniform one:
#
#   Claude Code  native plugin  (skills auto-load by description; hook injects the gate)
#   OpenCode     native plugin  (registers skills dir; injects the gate)
#   Codex        native plugin  (same as Claude Code); --codex writes AGENTS.md as a fallback
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$ROOT/core/GATE.md"
SUPER="$ROOT/core/SUPERPOWERS.md"
BEGIN="<!-- BEGIN senior-dephx -->"
END="<!-- END senior-dephx -->"

say() { printf '  %s\n' "$*"; }

render_agents_block() {
  printf '%s\n' "$BEGIN"
  printf '<!-- Managed by senior-dephx. Edits between these markers are overwritten. -->\n\n'
  printf '# How I work\n\n'
  cat "$GATE"
  printf '\n## Full skills\n\n'
  printf 'The gate above is always loaded. Read the matching file below when the work calls for it:\n\n'
  for d in "$ROOT"/skills/*/; do
    name="$(basename "$d")"
    desc="$(awk '/^description:/{sub(/^description: */,""); print; exit}' "$d/SKILL.md")"
    printf -- "- \`%s\` — %s\n  \`%sSKILL.md\`\n" "$name" "${desc:0:150}…" "$d"
  done
  # The other two adapters detect the sibling plugin at runtime and emit this only when it
  # is really there. Codex has no runtime, so the text goes in unconditionally and the
  # condition moves into the prose. Same file, never re-typed: a second copy of the map
  # would drift from the one the hooks emit.
  if [ -f "$SUPER" ]; then
    printf '\n> **Read the next section only if `superpowers` is installed here.** This plugin\n'
    printf '> stands alone and needs nothing else; everything above holds on its own, and it may\n'
    printf '> work even better alongside that plugin. IF those skills are present, they and these\n'
    printf '> defer as described below. If they are not, skip it: nothing named there is required\n'
    printf '> for any rule above to hold.\n\n'
    cat "$SUPER"
  fi
  printf '\n%s\n' "$END"
}

install_codex() {
  local target
  if [ "${1:-}" = "--here" ]; then target="./AGENTS.md"; else
    mkdir -p "$HOME/.codex"; target="$HOME/.codex/AGENTS.md"
  fi

  if [ -f "$target" ] && grep -q "$BEGIN" "$target"; then
    # Replace only our block; never touch what else lives in the file.
    local tmp; tmp="$(mktemp)"
    awk -v b="$BEGIN" -v e="$END" '
      $0 ~ b {skip=1; print "___SENIOR_DEPHX_BLOCK___"; next}
      $0 ~ e {skip=0; next}
      !skip {print}
    ' "$target" > "$tmp"
    local block; block="$(mktemp)"; render_agents_block > "$block"
    awk -v f="$block" '
      /___SENIOR_DEPHX_BLOCK___/ {while ((getline line < f) > 0) print line; next}
      {print}
    ' "$tmp" > "$target"
    rm -f "$tmp" "$block"
    say "updated $target (existing content preserved)"
  else
    [ -f "$target" ] && printf '\n' >> "$target"
    render_agents_block >> "$target"
    say "wrote $target"
  fi
}

install_opencode() {
  local cfg="$HOME/.config/opencode/opencode.jsonc"
  say "add this to the \"plugin\" array in $cfg:"
  say ''
  say '    "senior-dephx@git+https://github.com/ephraimd/senior-dephx.git"'
  say ''
  say 'or for local development, symlink the skills instead:'
  say "    mkdir -p ~/.config/opencode/skills"
  for d in "$ROOT"/skills/*/; do
    say "    ln -sfn $d ~/.config/opencode/skills/$(basename "$d")"
  done
}

install_claude() {
  say 'add the marketplace, then install:'
  say ''
  say '    /plugin marketplace add ephraimd/senior-dephx'
  say '    /plugin install senior-dephx'
  say ''
  say 'or for local development:'
  say "    /plugin marketplace add $ROOT"
}

case "${1:---all}" in
  --codex)    echo "Codex:";     install_codex "${2:-}" ;;
  --opencode) echo "OpenCode:";  install_opencode ;;
  --claude)   echo "Claude Code:"; install_claude ;;
  --all)
    echo "Codex:";       install_codex
    echo; echo "OpenCode:";  install_opencode
    echo; echo "Claude Code:"; install_claude
    ;;
  *) echo "usage: install.sh [--all|--codex [--here]|--opencode|--claude]" >&2; exit 1 ;;
esac
