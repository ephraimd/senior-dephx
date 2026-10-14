---
name: reviewing-for-ux
description: Use when reviewing any change or plan that touches a user-facing surface - a new page, screen, route, modal, drawer, label, button, empty state, or flow - for whether a non-technical user can find it, understand it, and not be hurt by it. Fires alongside code review of frontend diffs, where the experience is invisible in the code and the review's attention drains into code-level findings; fires on any new navigation entry point, any destructive action, any status indicator, and any screen a first-time user will meet. Covers where the surface lives versus how often users need it, the zero-data first-run screen, consistency with the app's existing pattern for the same interaction, labels a layman can read, destructive affordance proportional to blast radius, stacked modals and color-only signals, and whether the screen has a hierarchy at all.
---

# Reviewing For UX

`reviewing-for-scale` asks whether the change survives the data it will have. This pass
asks a different question about the same diff: **whether the change survives the user it
will have** - one who never read the code, never met the builder, and will not be trained.

A UI diff shows markup and handlers. It does not show the experience. A review of a
user-facing change whose findings are all code-level has skipped this pass, not passed
it - the experience failures were simply invisible in the text you were reading. You have
to reconstruct the screen, then review the screen.

## The rule

**Review as the newest user, not as the builder.** The builder knows where the page is,
what the words mean, and what happens when they click. The user knows none of that, and
the product's job is that they never have to be told. "QA clicked through every flow"
proves the flows work for people who already know them - it cannot prove a stranger can
find them, read them, or survive them.

## 0. Establish the review contract

Read the project's current canonical UI standards, approved copy and interaction
patterns before judging a diff. Name the sources and relevant constraints. Apply the
project's requirements; do not import another product's brand, domain vocabulary,
palette or structure. `ui-craft` owns the detailed construction rules. This review
checks whether users experience them. A subagent's report is evidence to verify, not
approval. Exceptions need explicit human approval recorded with scope and reason.

Also inspect enforcement: do root instructions discover those sources, do delegated
agents read them, and do meaningful regression tests and a required evidence gate cover
all changed UI before publication? Use existing coverage. Missing or disconnected
coverage is a concrete finding; read-only review does not authorize setup writes.
`ui-craft` routes authorized setup through its repository-guardrails reference. Verify
reported gate failures/passes and CI wiring rather than accepting a setup checklist.

## 1. How does the user get here on day 30?

**The entry point in the diff is how the builder reaches the surface; ask how a user
reaches it after they've forgotten where they found it.** Prominence must match frequency
of use, and peer features must live in peer places.

- A surface users will check daily - health, status, a work queue - buried behind a button
  inside another feature's settings is a discoverability failure even if the button is a
  perfectly nice button. And when a sibling feature of the same rank already has a
  top-level entry, the inconsistency is the finding: users learn where a *kind* of thing
  lives, and this breaks the lesson.
- A contextual shortcut is fine *in addition to* a findable home, not instead of one. Ask
  which this is.
- The tell in yourself: praising an entry point because it exists and works. That the
  builder could add a button somewhere is not evidence it belongs there.

## 2. Review the screen with zero data

**Every screen has a first-run state, and the diff almost never renders it.** Walk the
component as a brand-new account: no rows, no stats, nothing. What paints?

- A bare table of column headers reads as "the page is broken," on the first screen the
  newest - most fragile - user meets. The empty state that says what this is and offers
  the first action is the cheapest onboarding the product will ever ship.
- Empty, loading, and error are three different states. A review that catches the missing
  error handling has not thereby covered empty; an empty-looking screen that is actually
  an unreported fetch failure is both at once.

## 3. Survey the app before approving the pattern

**Inconsistency is invisible in a diff, because the diff only contains one of the two
patterns.** Before approving any interaction - a confirmation, a status indicator, a
modal versus a drawer, a form layout - go find how the app already does that interaction.

- A second way to confirm a delete, a second style of status display, a second table
  implementation: each is a fork the user pays for (the product stops behaving
  predictably) and the codebase pays for (the copies drift - `reviewing-for-scale` rule 5,
  wearing a UI).
- "The new pattern is better" does not settle it. Better-and-inconsistent loses to
  consistent; if the new pattern really is better, the finding is "migrate all of them,"
  not "ship the second one."

## 4. Read every label as a layman

**If a word names the system's plumbing rather than the user's task, it does not ship.**
Queue lags, TTLs, thresholds, sync internals - to a non-technical user these are noise at
best and alarming at worst, and they leak the architecture to every screenshot.

- The test: would the target user say this word to a customer? If not, translate it into
  their task ("Sending capacity", "Up to date") or move it to an ops dashboard.
- This includes what the metric *is*, not just what it is called. A number the user
  cannot act on is not information, it is decoration that competes with the numbers that
  matter.

## 5. Weight the control to the damage

**The friction of an action must be proportional to its blast radius, and the diff often
gets it exactly backwards.** Deleting one thing behind a confirm while deleting fifty
behind a bare button is the canonical inversion - selection is not consent.

- Stacked modals, row-clicks that fight their own checkboxes, meaning carried by color
  alone: each works in the builder's hands and fails in a stranger's. Color-only status
  is also an accessibility failure outright - pair the dot with a word.
- For any destructive control ask: what is the widest thing one stray click destroys, and
  does the screen make that width visible before it happens?

## 6. The screen must answer: look here first, do this next

**A grid of nine equal cards answers no question.** Every screen is implicitly asked
"what matters right now, and what do I do about it" - hierarchy is the answer, and
uniform weight is a refusal to answer.

- The fix is usually subtraction (rule 4 already removed the cards that don't belong)
  plus emphasis: the one or two numbers that drive action get the weight, the rest
  support. If everything is promoted, nothing is.

## 7. Follow the growing data and the failed action

Grow the list: can the user still find every independent task without passing all rows?
Check bounded results, persistent filters and visible sections. Shrink the container:
can a narrow dialog on a wide browser stack its content, show full URLs and reach its
last field and footer? On a phone, can users discover every section without guessing a
hidden horizontal strip? Verify focus entry, keyboard movement and return on dismissal.

Click each changed action through waiting, success, refusal and failure. Confirm that
unknown capability is distinct from confirmed Off and permission denial, that input and
retained answers survive failure, and that older results are labelled. Paid retries,
consent and approval follow the project's safeguards. Automation explains its trigger,
destination and next event; conflicts expose the owning rule and the permitted next
step. Assignments show the record, owner and next task together.

Check every metric's population, period, scope and freshness against its producer.
Page subtotals, filtered totals and global totals must not masquerade as one another.
Unknown data is not zero, activity is not unique users and accepted work is not completed
work. Follow a changed filter into paging, export and scheduled output where applicable.

## Review the work under interruption

Check dirty input during refetch, edits made while Save is pending and changing resource
or account before an old response arrives. Confirmation belongs to the submitted
snapshot, not everything currently visible. Cold failures must not expose blank editable
records; retained failures keep drafts/results visible. Unknown availability differs
from Off; zero differs from missing fees. Check actual consent/payment/status contracts.

In native apps inspect keyboard-open short screens, large text, safe areas, Android back,
screen-reader focus, last-row menus and returning from details. Matched action sizes and
compact statuses must preserve touch targets. Required tasks remain reachable with many
records; substantial authoring is not buried in a short dialog. A contextual shortcut
does not replace a findable home or clear default-field/scope explanation.

For camera/server-confirmed work, trace repeated callbacks, permissions, backgrounding
and timeouts after commit. Feedback is not admission; no cached/optimistic success or
blind replay when confirmation is required. Performance findings need release-build
measurements on physical devices, not a development simulator or vendor benchmark.
Report missing evidence and approved exceptions plainly; green logic tests do not fill
the gap. Keep private account data scoped and out of another account's restored view.

## Ranking UX findings

**A user who cannot find the feature, or who deletes three campaigns' infrastructure from
one campaign's settings page, is a product failure of the first rank - not a "product
polish" footnote below the code findings.** Rank by blast radius on the user, interleaved
with the correctness and scale findings, worst first.

- The habitual failure is structural: a review that puts every experience finding in a
  final "Product" or "Nice to have" section has pre-decided they lose to whatever came
  above. Some do. The discoverability failure and the inverted delete usually don't.
- Say which findings you *walked* (rendered the empty state, followed the click path) and
  which you inferred from the code. Same honesty bar as a scale claim.

## Red flags

| You see... | It means |
|---|---|
| A UI diff review whose findings are all code-level | The experience pass was skipped, not passed |
| A new surface reachable only from inside another feature | Discoverability failure; day-30 users won't find it |
| A peer feature with a top-level entry this one lacks | The navigation lesson users learned just broke |
| No branch for the zero-data case in a new screen | First-run users meet a screen that looks broken |
| A second pattern for an interaction the app already has | A fork the user and the codebase both pay for |
| Infrastructure vocabulary in a user-facing label | The plumbing is leaking into the product |
| Bulk destruction with less friction than single | Inverted safety; selection is not consent |
| Status carried by color alone | Fails colorblind users and ambiguous-by-design |
| A modal spawning a second modal | A pattern that works only in the builder's hands |
| Equal visual weight on every element of a screen | The screen refuses to say what matters |
| Every UX finding filed under "Product" at the end | The ranking was decided before the review |

## Review output

Return the verdict and user-impact findings first. For each finding identify the affected
path, contract requirement, concrete scenario and recovery. Then report the canonical
sources loaded, rendered workflows and viewports, keyboard/focus checks, observed state
outcomes, regression checks and limitations. Separate what was exercised from what was
inferred. Do not demote experience failures to optional polish, approve from compilation
alone or claim a fixture proves an unexercised live workflow.
