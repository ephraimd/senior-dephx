# Codex

Codex reads this repo's Claude Code marketplace as it is, and the plugin works there the
same way: the skills load from it, and its SessionStart hook injects the gate at the start
of every session.

## Install

```sh
codex plugin marketplace add ephraimd/senior-dephx
codex plugin add senior-dephx@senior-dephx
```

Codex runs a plugin's hooks only after you trust them, and records the trust in
`~/.codex/config.toml` under `[hooks.state]`. Approve senior-dephx's SessionStart hook when
Codex asks; until then the skills load but the gate does not.

## Update

```sh
codex plugin marketplace upgrade senior-dephx && codex plugin add senior-dephx@senior-dephx
```

## Without plugin support

`install.sh --codex` is the fallback for a Codex that cannot install plugins:

```sh
./install.sh --codex           # writes ~/.codex/AGENTS.md (global, every project)
./install.sh --codex --here    # appends to ./AGENTS.md (this project only)
```

It writes the gate, always on, plus a pointer to each skill's `SKILL.md` by absolute path,
so run it from a clone you keep. If the file already exists, the installer appends a
delimited block and rewrites only that block on re-run, so anything else in it survives.

Use the plugin or this, not both. With the plugin's hook trusted, an `AGENTS.md` block
loads the gate a second time in every session.
