# Codex

Codex installs this repo as a plugin, from the same marketplace Claude Code uses, and gets
the skills from it. What a Codex plugin cannot do is run hooks, so the SessionStart hook
that injects the gate in Claude Code never fires there.

So Codex gets the gate from `AGENTS.md` instead: `~/.codex/AGENTS.md` is read in every
session, which is exactly the always-on residency the gate needs. The skills stay what they
should be, loaded when relevant; the gate is the part that must always be present.

## Install

```sh
codex plugin marketplace add ephraimd/senior-dephx
codex plugin add senior-dephx@senior-dephx      # the skills

./install.sh --codex           # the gate, in ~/.codex/AGENTS.md (global, every project)
./install.sh --codex --here    # or appends to ./AGENTS.md (this project only)
```

Global is usually what you want: judgment shouldn't be per-repo.

Run `install.sh` from a clone you keep. Besides the gate, the block lists every skill with
the absolute path of its `SKILL.md` in that clone, as a fallback for a Codex without the
plugin. A clone in a temp directory or a worktree that gets cleaned up leaves those paths
pointing at nothing.

If `~/.codex/AGENTS.md` already exists, the installer appends a delimited block and
rewrites only that block on re-run, so anything else in the file survives.

## Update

```sh
codex plugin marketplace upgrade senior-dephx && codex plugin add senior-dephx@senior-dephx
git pull && ./install.sh --codex
```
