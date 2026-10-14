---
name: ui-craft
description: Use when building, reviewing or redesigning components, marketing pages, dashboards, dialogs or navigation, especially when UI feels inconsistent, abstract, cramped, silently unresponsive or difficult to use on a phone.
---

# UI Craft

Ship UI that looks like a **deliberate product, not a generated template**.

This skill is the visual-quality bar. It deliberately names no components, no colours and
no class names, because yours are not mine: **discover the project's primitives and
conventions first, then hold them to these rules.** A rule that arrives with someone
else's nouns attached is the very slop this skill exists to stop.

**Core principle:** every screen should look hand-made and consistent. The fastest tells
that it wasn't: repeated decorative chrome, copy-pasted styles that drift, and wasted
space before content.

## 0. Bind to the project first

Before applying anything below, spend two minutes learning the local truth:

- **What is the UI contract?** Find the repository instructions and canonical design,
  UX, copy and accessibility standards. Read their current version and approved examples.
  Name the sources and constraints applied. Existing screens can contain known defects;
  an old implementation does not override the standard. If no contract exists, report it
  and resolve necessary design decisions within the authorized scope.
- **Where do primitives live?** Find the shared component directory and read its index.
  That list is your vocabulary.
- **What is the canonical primary action?** Find the button every main CTA uses. There
  should be exactly one.
- **Is there an accent map?** Find how domain areas are colour-coded, in a theme file or by
  convention.
- **What persistent chrome exists?** A fixed bottom nav, a sticky header, a sidebar. These
  are collision surfaces.
- **What targets does this change serve?** Read supported platforms and sizes; use
  analytics when available, without assuming audience share from a screenshot.

If any of these do not exist, that absence **is a finding** worth reporting - not a licence
to invent a parallel one mid-feature.

### Establish enforcement before implementation

For authorized UI work, inspect the project's repository guardrails. Reuse complete
coverage, extend partial coverage and establish missing checks in its existing rules,
runtime and CI. Follow [repository-guardrails.md](references/repository-guardrails.md)
before editing UI when enforcement is missing or incomplete. This setup is part of the
implementation, not an optional follow-up. Preserve existing instructions and stronger
policy. Read-only reviews report gaps; non-UI tasks do not create UI tooling. Startup
hooks never perform repository writes. Subagents read current sources independently.

Report **Guardrails: reused / extended / created**, canonical sources/version, local
command, CI entry and trusted base, positive/negative evidence and remaining gaps.
An unwired gate, invented evidence or a convenient narrow diff is incomplete setup.

## 1. No AI slop

The #1 "made-by-AI" tell is the **decorative eyebrow pill**: a colored capsule → giant
heading → one-sentence subhead, repeated on every section in lockstep.

- **Remove decorative section-eyebrow pills.** Let sections open with the heading. Vary
  openers across a page - don't repeat one rhythm.
- **Keep only functional badges.** A badge is functional if it conveys live state, data, or
  status - a count, a `FREE` tag, an approval state. It's decorative (remove it) if it's
  just a label or a section eyebrow.
- **Don't over-animate.** Every element floating in on a staggered delay reads as
  templated. Prefer a single subtle transition, or nothing.
- **Structure must encode something true.** Numbered markers (01 / 02 / 03) belong on
  content that genuinely is a sequence. Decorative numbering is chrome pretending to be
  information.

## 2. One source of truth (kill copy-paste)

Inconsistency comes from hand-copied style strings that drift - one padding step here, a
slightly different one there; solid in one place, gradient in another. If you're pasting
the same style soup a second time, that's the bug.

- **Use the project's primitives.** Import them; don't rebuild them inline.
- **One canonical primary action.** A second "primary" style is drift, not a variant. If
  you find two, that is a bug to report, not a choice to copy.
- **Extract a primitive into the shared directory** once `engineering-standards` §1 says it
  is time, following whatever variant mechanism the project already uses. Do not introduce
  a second mechanism, and do not add a styling library the project does not already have.

Native apps follow the same rule through their approved native kit; web primitives are
not a native implementation. A utility styling tool is not a complete interaction kit.
Compose missing pieces from existing primitives and platform controls before adding a
library. Verify needed component maturity and compatibility; alpha means prerelease,
not paid. Add only used components, not an entire catalogue for hypothetical needs.

## 3. Density - content above the fold

Chrome before content is the second-biggest waste. Don't stack five centered blocks
(eyebrow → H2 → subhead → stats → tabs → pills) before the first card.

*The fold = the first viewport (~700px on desktop, the first screen on a phone). The thing
the user came for - cards, the listing, the form - should appear within it.*

- **Compact toolbars:** heading left, controls (tabs/sort/search) right, in ONE row on
  desktop.
- **Collapse secondary explainers** (a 3-card "how it works") into a slim inline strip.
- **Trim section padding.** Enormous hero padding is rarely earned; inner sections need
  far less than they are usually given.

Related action-row buttons use the same size variant. Keep status pills compact while
preserving platform-appropriate touch targets. Small radio/checkbox visuals sit inside
labelled targets. Center labels through the shared primitive, not per-screen offsets.
Choose consistent page/screen roles and gutters; loading/error/empty states inherit the
same frame. Project values own the measurements, not a portable plugin's sample pixels.

### Bounded worklists and a stable mental model

Never put an independent section, form, control or status below a growing list. Keep
scope, named sections and task controls before results. Pagination and row-owned
feedback may follow their list. Separate peer datasets with the established tabs or
labelled menu; use a short dialog for a focused task, a drawer for contextual detail and
a page for substantial authoring. Long content alone does not justify hiding necessary
work in a dialog. Bound result sets, preserve filters during paging and label result caps.

## 4. Mobile-first

Design for the project's supported phones from the start; audience share requires evidence.

- **Size dialogs to their task and their container.** Internal columns depend on the
  dialog's available width, not the browser's width. Check a narrow dialog on a wide
  screen. Wrap complete shared URLs and pair copying with a manual fallback on refusal.
  Keep a labelled close control, viewport-bounded scroll area and reachable footer
  actions. Moving focus to the final field must scroll it into view; dismissal restores
  focus to the trigger. Expandable form groups retain values when collapsed.
- **Expose every section on a phone.** A hidden horizontal tab strip is not discoverable
  navigation. Use a labelled selector or the project's accessible menu pattern when needed.
- **Modals MUST scroll on mobile.** Centring a tall modal clips its top off-screen and the
  content becomes unreachable. Follow the project's modal pattern if it has one; if it
  doesn't, that is a finding.
- **No control-row jammed beside a component that needs the width.** On mobile, controls
  stack below, full-width.
- **Beware fixed-bottom CTAs.** They collide with any persistent bottom nav. Prefer an
  in-flow footer after the form; offset above the nav only if a sticky bar is genuinely
  needed.
- **Image-led cards go 1-col on mobile.** Two cards per row on a ~390px screen is ~165px
  each - slender and cheap-looking. Give them full width, with a modest aspect ratio.
- **Tighten padding responsively.** Desktop padding on a phone reads as bloat.

For native apps, safe areas, the visible keyboard and system back behavior are part of
the layout contract. On a short phone, the first/last fields, close and Save remain
reachable with large text and the keyboard open. Keep one shared overlay owner; avoid
duplicate focus/dismissal/scroll handlers. Test final-row menus against screen edges and
restore accessibility focus after dismissal. Use existing native navigation rather than
hand-built headers or nested dialogs without a product need. Virtualize growing records;
keep chat composers outside transcript scrolling. Phone browser screenshots cannot
certify native keyboard, camera, accessibility or physical-device behavior.

## 5. Accent consistency

Accent roles and permitted surfaces belong to the project. Read its map rather than
assign a palette per feature. The canonical primary action remains consistent; a domain
accent may style an action only when the project's design system explicitly permits it.
Seller/tenant identity follows the project's ownership and disclosure rules without
silently redefining application controls or inserting acquisition distractions.

## 6. Words are design material

- Name things by what people recognise, not how the system is built.
- A control says exactly what happens; the confirmation says it happened.
- Errors explain what went wrong and how to fix it.
- **Self-documenting UI:** a setting should state its consequence. If a toggle changes what
  a user is charged, how long their money is held, or who can see their work, say so next
  to the control - dynamically, with their actual numbers in it.

### Action outcomes and concrete language

An action shows waiting, success or failure beside its control, with a useful next step.
Distinguish confirmed disabled, unknown availability, unavailable service, forbidden,
loading, successful empty and zero. A failed capability read must not become Off.
Preserve input and retained results on failure; label older results. Do not retry paid
operations automatically. An uncertain outcome needs status reconciliation and the
existing financial safeguards before another paid attempt.

Explain automation using its actual trigger, eligible records, destination, owner and
next event. A blocked control names the conflicting owner or rule and offers the next
permitted action. Show assignments by record and owner, with status and next task;
"already handled" is insufficient. Approved wording is preserved verbatim until a human
approves a change. Examples and benefit claims must match supported behavior, not imply
unavailable automation, accuracy or freshness. Use respectful situation-based language.

### Draft ownership and submitted snapshots

Hydrate by resource identity. Refetch does not replace dirty fields. Save captures the
submitted snapshot; its response acknowledges that version without erasing later edits
or another resource's draft. Preserve input on failed saves and apply the existing dirty
dismissal/back policy. Show explicit Save where users need certainty, with unsaved,
pending, confirmed and failed outcomes. A draft save must not imply sending/publishing.
Put contextual form-editing actions where users need them, explaining default fields
and scope. Zero is valid data, not permission to invent a fallback fee.

### Native performance and authoritative actions

Do not promise zero library/styling overhead. Define product budgets and profile release
builds on representative physical devices; record versions, hardware and measurements.
Separate startup, frames, touch latency and memory from network/server latency. Avoid
broad state subscriptions and unbounded records before adding optimization dependencies.
For scan-driven tasks, suppress duplicate frame callbacks while pending, handle camera
permission/focus/background and distinguish immediate feedback from confirmed success.
When a task requires server confirmation, cached eligibility does not authorize it.
Reconcile an uncertain write before replay; a request header alone is not idempotency.

## Red flags - stop and fix

| You see… | Do this |
|---|---|
| A colored eyebrow pill above a heading | Remove it (unless it's a functional badge) |
| The same class string pasted twice | Extract/import a primitive |
| Two different "primary" button styles | Converge on one; report the drift |
| 4+ stacked centered blocks before content | Collapse into a toolbar; raise the content |
| Controls jammed beside a tight component on mobile | Stack below, full-width |
| A fixed-bottom bar on a page that has a bottom nav | Use an in-flow footer, or offset above the nav |
| Image-led cards 2-col on a phone | 1-col on mobile; modest aspect ratio |
| Padding that feels bloaty on mobile | Tighten responsively |
| A placeholder avatar/monogram for an unsupported upload | Remove it - it reads as an unfinished feature |
| Dead/legacy duplicates (`Foo` + `FooNew`) | Delete the unused one |
| A setting whose consequence isn't stated | Say what it does, with real numbers |

## Before shipping

1. Build clean.
2. Run it and **look at it** on supported targets: desktop/phone widths for web, actual
   native screens for apps. A screenshot you do not examine is not verification.
3. Confirm: no decorative pills, primitives reused (not copy-pasted), content above the
   fold, no horizontal overflow.
4. **On the supported phone specifically:** padding tight not bloaty, cards balanced not
   slender, nothing a placeholder for a feature that doesn't exist. Actually look at the
   cards - don't just check "it renders".

For changed behavior, exercise realistic empty and large lists, long names and URLs,
waiting, failure, permission, unavailable and retained-data states. Inspect the smallest
supported phone, a short viewport and tablet/desktop when supported; test keyboard navigation,
focus, scrolling, persistent navigation collisions and scope-preserving paging.
Use the project's regression suite and record observed evidence separately from source
inference and untested cases. A fixture proves only the components and paths it exercises.
Do not rewrite baselines or weaken checks to hide a regression. Reload canonical sources
after compaction and give subagents the same contract and acceptance scenarios.

Proving it works end to end: `verify-for-real`.
