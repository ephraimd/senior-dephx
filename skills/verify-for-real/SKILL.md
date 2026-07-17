---
name: verify-for-real
description: Use before claiming any non-trivial change works, before opening a PR, and before any deploy. A compile or type-check is NOT verification - run the thing, exercise the path that changed, and read the output. Covers what to actually exercise, how to prove a test would fail without the fix, migration/backfill verification, and cleaning up what you started.
---

# Verify For Real

**A build is not a verification.** Compiling proves syntax. Type-checking proves shapes.
Neither proves the thing does what you said it does.

The rule: **run it, exercise the path that changed, and read the output.** Then say what
you observed, not what you expect.

If `verification-before-completion` is loadable, it owns the law - no completion claim
without fresh evidence - so point at it instead of re-arguing it, and spend your effort
here, on *what* to exercise. If it is not, this file carries both halves on its own.

## Why this is a skill and not a footnote

Real failures that a green build reported as fine:

- An endpoint compiled and returned 500 because it queried a table that did not exist.
- A DDL statement failed at runtime because the database does not accept bind parameters
  in DDL - and it *looked* correct because a later step happened to patch the same state.
- A migration was written to run once and would have re-run on every boot, silently
  overwriting real user choices.
- A worker started in the wrong process, so it ran once per API replica instead of once.

None of these are exotic. All of them survive `build` and `vet` and would have shipped.

## What to actually do

Scale to the blast radius. Trivial edits need none of this.

1. **Run the thing.** Start the app/service/CLI the way it really starts. Boot errors are
   free findings - read the log even when it starts fine.
2. **Exercise every path you touched.** Not the happy path you remember - the ones the diff
   changed. Hit the endpoint, click the flow, run the command, trigger the worker.
3. **Look at the output.** HTTP 200 with wrong JSON is a failure. A screenshot you did not
   examine is not verification. Read the error log for the underlying cause, not just the
   surface message.
4. **Check the data, not just the response.** If it writes, read the row back. If it
   migrates, query the result. "The migration ran" is not "the migration was correct".
5. **Prove the test would fail without the fix.** Revert the fix, watch the test go red
   with the real symptom, restore it. A test that passes against broken code is decoration.
6. **Run the whole suite**, not just your file. Your change's blast radius is not your
   file's blast radius.
7. **Do not trust a control plane's own success field.** "Accepted" is not "live". Read the
   resulting artifact back - its identity (digest, tag, version) and its timestamp - and
   confirm it is the thing you just shipped. An API that accepts a field and ignores it
   still returns 200.
8. **A green build with a failed deploy is configuration, not code.** Changing code first
   destroys the evidence and adds a variable to a system that already has too many. Read
   the config, the env, and the wiring before you touch a line.
9. **Clean up everything you started.** Kill the processes, remove the temp files and
   scratch scripts, close the browser. Never leave them for the human, and never commit
   them.

## Migrations, backfills, and workers

These deserve their own pass because their failure mode is silence.

- **Run it twice.** The second run must be a no-op. A backfill that re-runs will stomp
  real data.
- **Verify the values, not the row count.** "Backfilled 8 rows" says nothing about whether
  the 8 values are right. Read them.
- **Prove the guard.** Whatever stops it re-running - test that it holds after a state
  change a human would make.
- **Check the leftovers.** Rows the backfill could not resolve should be reported loudly,
  not left at a default that silently means something else.

## Reporting

- Say what you **observed**: the status code, the log line, the value in the row.
- Say what you did **not** verify and what is still unproven.
- If it failed, say so and show the output. A green summary over a red run is the worst
  thing you can produce, because it spends someone else's trust.
- Never describe work as done, fixed, or passing until you have watched it be so.

## Red flags

| You catch yourself… | Do this instead |
|---|---|
| "The build passes, so it works" | Run it and exercise the path |
| "The tests pass" (you never saw them fail) | Revert the fix; confirm red for the right reason |
| "The migration ran" | Query the values it wrote |
| About to say "should work" | Go and find out |
| Reporting a screenshot you didn't open | Open it and describe what is in it |
| Leaving a server on port X running | Kill it |
| Explaining why an unverified thing is probably fine | That paragraph is the tell. Verify it. |
| "The deploy came back accepted" | Read the artifact back; check its identity and timestamp |
| Changing code because a deploy failed | Read the config, the env, and the wiring first |
