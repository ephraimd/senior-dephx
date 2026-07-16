# Codex

Codex has **no plugin or skill system**. It reads `AGENTS.md` — repo root, and
`~/.codex/AGENTS.md` globally — and that is the whole extension surface. There is no
`/skill` invocation and no loading-by-description.

So Codex gets the gate **always-on**, and pointers to the rest.

That is a smaller capability than Claude Code or OpenCode get, and it is worth being
honest about. It is also arguably the right shape: the gate is the part that must always
be resident, and the domain skills are the part that should load only when relevant —
Codex simply cannot do the second half, so it reads them on request instead.

## Install

```sh
./install.sh --codex           # writes ~/.codex/AGENTS.md (global, every project)
./install.sh --codex --here    # appends to ./AGENTS.md (this project only)
```

Global is usually what you want: judgment shouldn't be per-repo.

If `~/.codex/AGENTS.md` already exists, the installer appends a delimited block and
rewrites only that block on re-run, so anything else in the file survives.
