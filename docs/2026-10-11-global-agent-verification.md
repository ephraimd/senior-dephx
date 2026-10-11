# Global runtime verification, 2026-10-11

Release: 0.9.0. The canonical gate and skills remain shared across runtimes. Project
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
