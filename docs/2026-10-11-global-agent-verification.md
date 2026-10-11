# Global runtime verification, 2026-10-11

Release: 0.9.1. The canonical gate and skills remain shared across runtimes. Project
standards, vocabulary, tooling, test scenarios and evidence remain consumer-owned.

## Preserved Go rewrite

Commit `984478936eef273a1d706cfce28941e755f41060` (October 3) is an ancestor of
this release. `git diff --quiet 9844789 -- skills/go-backend-blueprint skills/backend-shape`
passes. All eight files, including the six Go reference documents, match that rewrite.
The Go blueprint remains opt-in by explicit name, never an automatic Go refactor.

## Adapter checks

- `bash test/smoke.sh`: passes, including existing shell and OpenCode adapters and
  preserving user instructions during fallback setup.
- `bash test/ui-policy.sh`: passes.
- `python3 test/repository-guardrails.py`: 36 tests pass.
- `node --test test/claude-child.mjs test/pi-adapter.mjs`: four tests pass.
  The initial tests failed against the absent adapters before implementation.
- Native Claude child output parses as `SubagentStart` JSON and carries the exact gate,
  independently readable skill paths and project-source requirements. The existing
  SessionStart output remains plain context; shell hooks need no new runtime dependency.
- Pi's actual public child registration API is loaded using its own Jiti dependency
  when a release exports TypeScript. A native SDK probe passes normal and minimal
  sessions: gate added once, other policy retained, required child registration present,
  cleanup on shutdown, no extension errors. Minimal sessions disable ambient extensions
  and the skill catalog; the gate still supplies direct on-demand skill paths.
- The Pi unit lifecycle boundary double verifies registration disposal on a session
  switch and repeated shutdown, and warning without overwriting a competing registration.

## Behavioral probes and limits

The disposable consumer uses its own contract version 7, Tickets / Assigned agent /
Reply draft vocabulary, approved heading and existing Make/Python check. The review
request is read-only and names no plugin rules. Startup never bootstraps repository files.

A fresh Pi parent and foreground native child ran in the matching source runtime 0.84.4.
The child disabled global context, skills inheritance and ambient extensions. Its native
launch receipt lists `senior-dephx` under required extensions, with none omitted. It read
the canonical project sources, UI and UX skills and adaptive guardrail reference itself,
reported UX-1 through UX-4, preserved the approved wording, rejected misleading unknown
states, identified missing enforcement, exercised the original check and distinguished
source inference from unavailable browser evidence. No browser validation is claimed.

Claude's global native startup hook executes successfully in fresh sessions. An expired
OAuth session was renewed, after which the model call stopped at the account's weekly
usage limit. Actual Claude parent/subagent behavior remains unverified. Direct child hook
execution and manifest validation are local evidence, not a substitute for that run.

The installed Pi desktop bundle is missing Jiti's CommonJS entry point, causing all of
its configured extensions to fail before model execution. The operator declined app
bundle/signature repairs; no application files or signatures were changed. The source
runtime probes do not prove the installed desktop bundle's extension loading works.
Global package installation and byte checks are reported separately from desktop behavior.

Existing model settings, telemetry choices, global operator notes and unrelated plugins
are preserved. No claims are made about external CLI runners, intentionally disabled
policy, unsupported older subagent APIs or conflicting host registrations. Those cases
need their own runtime verification or produce an explicit registration warning.

## Final installation and the child skill-loading correction

Claude user scope and all three older project-scoped installations were upgraded, so
those copies cannot shadow the global policy. The registered Pi package is updated from
its normal Git source. Canonical gate, UI policy and all eight Go/backend files match the
installed artifacts. Pi settings, global operator notes, Claude settings and unrelated
Claude plugin metadata retain their recorded SHA256 fingerprints. The desktop bundle and
signature remain unchanged and signature verification passes.

The first globally installed Pi test passed project-rule adherence in fresh foreground
and background children, but transcript inspection found neither opened the full UI/UX
skills. This is a verification gap, not a full pass. Version 0.9.1 places exact on-demand
UI skill paths before the gate and explicitly requires both paths in every UI handoff.
Its regression assertions failed against 0.9.0 before the correction. A fresh controlled
source-runtime rerun confirms the parent, foreground child and background child actually
opened both skill files and the project sources independently. Both native child receipts
record the required extension and exit code 0. A final installed-artifact probe checks
discovery and registration separately from model behavior.

GitHub hosted run 38111903853 for the release failed with startup_failure and zero jobs.
Local checks and native source-runtime observations do not claim hosted CI success.
Claude model and subagent behavior remain blocked by the weekly limit; fresh native
startup-hook execution succeeds. Pi desktop extension loading remains blocked by its
existing missing Jiti entry point, under the operator's instruction not to repair the app.
