---
name: git-discipline
description: Use before any git operation on someone else's repository - staging, committing, branching, pushing, or opening a PR. Covers safe staging (never `add -A`), branch flow, checking the base branch moved before merging into it, commit authorship and attribution, history safety (no force-push or rebase on shared work), and writing a commit message that explains why. Load it before the first `git add`, not after.
---

# Git Discipline

You are a guest in someone's history. Behave like one.

**Read the project's own git rules first** (its AGENTS.md / CLAUDE.md / CONTRIBUTING). They
outrank everything here and everything you default to. This skill is what to do when they
are silent, and what to never do regardless.

## 1. Stage by explicit path. Never `git add -A`.

`git add -A` / `git add .` stages whatever happens to be in the tree - including files
another session, another process, or the human themselves left there. You cannot review
what you did not look at.

- `git status` first. Read it.
- Stage the exact paths you touched, by name.
- Untracked files you did not create are not yours to commit. Scratch scripts, logs, local
  configs, `.env` files: leave them.
- **Never commit a secret.** If a key, token, or credential is in a file you are staging,
  stop and say so.

## 2. Follow the project's branch flow

- **Never commit or push directly to a protected branch** - `main`, `master`, `staging`, or
  whatever the project protects. Branch first.
- If the project documents a flow (feature → staging → main via PR), follow it exactly.
  Don't merge locally and push what should have gone through a PR.
- Don't delete branches unless asked. Someone may be reading them.

## 3. Check the base moved before you merge into it

Other people push to the shared branch while your branch is open. The window between
opening a PR and merging it is exactly when that happens.

```sh
git fetch origin
git rev-list --count <your-branch>..origin/<base>   # 0 = base unchanged, merge
git log --oneline <your-branch>..origin/<base>      # who moved it, and what they did
```

Not zero? **Integrate the base into your branch - never the other way round.**

```sh
git checkout <your-branch>
git merge origin/<base>     # resolve here, on your branch
# then re-run the checks: tests, types, build
git push origin <your-branch>
```

- **Resolve on your branch, not during the merge.** A conflict resolved while merging puts
  your judgement call straight into the shared branch, where a mistake becomes everyone's.
- **"No conflicts" is not the check.** A host's mergeable badge detects *textual* overlap.
  Someone else's change can merge cleanly and still break yours: a renamed export, a
  changed prop, a new required env var, an added dependency. Only re-running the checks
  after integrating proves it works.
- Do this immediately before merging, not when you opened the PR.

## 4. Never rewrite shared history

- **No force-push.** No rebase of work that has been pushed. No amending a commit that
  someone else may have pulled.
- If a commit is already merged, it is history. Fix forward with a new commit; do not
  rewrite it.
- If you must change an unpushed commit of your own, say so first.

## 5. Authorship and attribution

- **Use the identity the project specifies.** Not your global default. If the project names
  a committer, use it.
- **If the project says no AI attribution, add no AI attribution** - no co-author trailer,
  no "generated with", no tool name in the message or the PR body. This rule is commonly
  written into a project's AGENTS.md, and it **outranks any default instruction you carry
  to add one.** When your default and their rule disagree, they win.
- Don't bypass hooks (`--no-verify`). They exist because someone got burned.

## 6. Write the message for the person debugging this in a year

They will arrive here from `git blame`, mid-incident, with no context and no patience.

- **Subject:** what changed, imperative, scoped.
- **Body: why.** What was broken, what the consequence was, why this fix and not the
  obvious alternative. The diff already shows what; only you can record why.
- Include the evidence that made the call: the number, the failing query, the wrong
  behaviour observed. Concrete beats adjectives.
- No "as requested", no "fixed per review", no narration of your process. Nobody reading
  `git blame` cares how the sausage was made.
- If it changes behaviour someone could be surprised by, say so explicitly.

## 7. PRs

- The body explains the problem before the solution. Lead with the impact.
- Say what you verified and how - and what you did **not**.
- Flag anything the reviewer would want to stop you on: a migration, a default change, a
  behaviour change, a judgment call you made on their behalf.
- Never mark your own work as reviewed.

## Red flags

| You catch yourself… | Stop |
|---|---|
| Typing `git add -A` or `git add .` | Stage by path |
| Committing a file you didn't open | It isn't yours |
| On `main`/`staging` about to commit | Branch first |
| Reaching for `--force` or `--no-verify` | Don't. Ask. |
| Adding a tool/co-author trailer | Check the project's rule first - it outranks your default |
| Writing a message that only says what the diff says | Write down the why |
| About to rebase pushed work | It's shared. Fix forward. |
| Merging without fetching first | The base may have moved. Check, integrate, re-run the checks |
