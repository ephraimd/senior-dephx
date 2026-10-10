# Establish project-owned UI guardrails

Use this during authorized UI implementation or a requested guardrails setup. The
startup hook only injects guidance. It never writes to the consuming repository.
For read-only work, inspect coverage and report concrete gaps without changing files.
Non-UI work does not bootstrap UI tooling.

## Assess, then reuse or extend

Read root and nested instructions, canonical UI/design/copy sources, shared primitives,
package/build commands, tests, PR guidance and every CI path that can publish affected UI.
Trace monorepo packages, static assets and public copy as well as components. Inspect the
implementation of an existing gate, not just its name or a green check. Identify coverage
for deletions, renames, new files, shared behavior and failures. Record what is already
covered and what is missing.

If equivalent enforcement exists, use it and repair only demonstrated gaps. If it is
partial, extend that same gate and workflow. A second checker or instruction hierarchy
makes drift more likely. If none exists, establish the following in the project's
existing locations and runtime:

- One canonical practical UI contract with stable local rule IDs. Preserve stricter
  rules, approved wording, terminology, tokens, supported devices and existing authority.
  Where standards are absent, write the applicable portable baseline from `ui-craft`
  and `reviewing-for-ux`, grounded in the actual UI. Do not invent approved copy or silently
  decide missing branding. Ask only for a real unresolved policy or product decision.
- Root instructions for current-source discovery, reload after compaction/checkout,
  subagent handoff and independent reading. Extend existing instructions or delegation
  chains; retain their contents. Subagents receive canonical paths/version, relevant
  rule IDs, changed paths and acceptance scenarios.
- A project-owned review record/template: exact changed paths, current source and contract
  versions, applied rules, observed workflows, local test results, inspected screenshots
  at the project's supported viewports, unproven cases and explicit human-approved
  exceptions. Preserve approved copy with an independent source and regression test.
- A runnable review gate, meaningful behavior regressions and one documented local
  command. Use existing test tools. New tooling requiring an unresolved dependency or
  runtime choice is a reported setup gap, not a reason to silently skip enforcement.
- Existing CI that runs the gate and relevant tests before merge/publication, plus
  concise existing PR guidance. Keep unrelated jobs, triggers, permissions and release
  semantics. Protect the enforcement files themselves through the existing review process. New coverage must not be only an optional standalone workflow.

Routine local setup within authorized implementation proceeds without another setup
question. A policy conflict or proposed weakening needs the human's decision. Do not
commit, push, deploy, change remote protection or access settings solely because setup
was requested. Follow the consuming project's existing delivery authorization.

## Portable gate asset

If no equivalent checker exists and the project already supports its interpreter,
copy `../assets/check-ui-review.py` into the project's scripts/tools directory. It is a
self-contained standard-library example, not a dependency on the installed plugin cache.
Adapt to the existing runtime when necessary; retain its failure semantics and tests.
Keep configuration, tests and instructions in the consuming repository.

Configuration version 1 uses these project-selected fields:

```json
{
  "version": 1,
  "ui_paths": ["client/", "public/"],
  "canonical_files": ["docs/experience.md", "docs/voice.md"],
  "guardrail_files": ["AGENTS.md", "tools/check-ui-review.py", ".github/workflows/checks.yml"],
  "rule_ids": ["UX-1", "UX-2", "UX-3", "UX-4"],
  "review_dir": "reviews/ui/",
  "evidence_dir": "reviews/images/",
  "viewports": ["phone", "short-phone", "tablet", "desktop"],
  "checks": ["unit", "browser"]
}
```

Protect instructions, checker and CI definitions in `guardrail_files`. Directories end
in `/`; other entries are exact files, not globs. Choose actual source
roots and the project's viewport names and dimensions. This sample does not prescribe
folder names, devices, commands or a documentation hierarchy.

Run the copied checker with `python3 <project-script> --config <project-config> --base
<trusted-base>`. A record has `version: 1`, the resolved base commit, a reviewer, `paths`
(path to current SHA-256, or null for deletion), `standards` (same for canonical files),
`rules`, `scenarios` (scenario and observed result), `checks` keyed by configured check
name (command, result `pass`, observed result), `screenshots` keyed by viewport (path,
SHA-256 in `sha256`, inspected finding), `limitations` and `exceptions` (paths, reason, approval reference).
Policy-only setup records need observed local checks and authorization references for
changes to existing enforcement, but no UI screenshots. A genuinely new contract/config
with no UI or existing-policy changes uses the initial setup path. No visual verification
is claimed by that path.

Review records must be new or updated in the diff. Hashes bind evidence to current files
and screenshots;
PNG integrity and JPEG/WebP headers are validated. The gate cannot authenticate approval,
decode all image formats or prove that an observation is true. Human inspection and
behavior tests remain mandatory. Do not populate records with invented passing results.

## Wire the trusted base and prove enforcement

For PRs, use the trusted target base from the host and fetch its history. In publishing
pipelines, use the last successfully checked/published commit for that branch, or an
existing reviewed baseline that covers the entire pending release. `HEAD`, a convenient
recent commit, a caller override or the previous push alone can hide earlier unchecked UI.
Missing, unrelated or unavailable baseline history fails closed. Use the repository's
bootstrap procedure for a new history; do not claim an empty diff proves enforcement.

Test the real gate and actual CI wiring in a disposable checkout: an unreviewed UI change,
rename/deletion, missing viewport, failing check and stale evidence must fail; a genuinely
complete record must pass. Exercise existing checks after setup on the consuming CI runtime and operating system.
Use platform temporary-directory APIs; never embed the author's machine paths in generated
tooling or tests. Rerun setup: it must
leave equivalent enforcement intact, without duplicate instructions, gates or workflows.
A gate-record validator cannot prove CI ran it or tests exercised the real feature.

Finish with **Guardrails: reused / extended / created**, sources and versions, local
command, CI entry and trusted base, observed positive/negative checks, and remaining gaps.
Do not call setup complete while enforcement is disconnected or evidence is unavailable.
