#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
python3 - <<'CHECK'
from pathlib import Path
import os, re
r=Path(os.environ['ROOT'])
gate=(r/'core/GATE.md').read_text()
ui=(r/'skills/ui-craft/SKILL.md').read_text()
ux=(r/'skills/reviewing-for-ux/SKILL.md').read_text()
assert 'UI contract' in gate, 'startup gate does not require project UI contract discovery'
assert 'ui-craft' in gate and 'reviewing-for-ux' in gate, 'startup gate does not require both UI skills'
assert 'growing list' in ui, 'growing-list placement rule is absent'
assert 'container' in ui, 'dialog container sizing rule is absent'
assert 'retained' in ui, 'retained-result rule is absent'
assert 'filtered' in ux, 'scoped-total review rule is absent'
assert 'subagent' in gate, 'subagent handoff rule is absent'
assert 'approval' in gate, 'exceptions lack an approval requirement'
for p in [r/'core/GATE.md', r/'skills/ui-craft/SKILL.md', r/'skills/reviewing-for-ux/SKILL.md']:
    text=p.read_text()
    assert not re.search(r'(?:/Users/|/home/|https?://)', text), f'consumer path or host leaked into {p.name}'
    assert not re.search(r'\+\d{8,}', text), f'recipient detail leaked into {p.name}'
print('UI policy contract: PASS')
CHECK
output="$(CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/hooks/session-start.sh")"
[[ "$output" == *"UI contract"* ]] || { echo 'Hook did not emit UI contract'; exit 1; }
echo 'UI policy hook: PASS'
