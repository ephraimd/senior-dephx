---
name: ui-craft
description: Use when building, reviewing, or redesigning any UI - components, landing/marketing sections, dashboard surfaces - or when something looks AI-generated/templated, feels visually inconsistent, wastes vertical space, or breaks on mobile. Covers de-slopping, primitive reuse, layout density, accent consistency, and the mobile-first verify bar.
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

- **Where do primitives live?** Find the shared component directory and read its index.
  That list is your vocabulary.
- **What is the canonical primary action?** Find the button every main CTA uses. There
  should be exactly one.
- **Is there an accent map?** Find how domain areas are colour-coded, in a theme file or by
  convention.
- **What persistent chrome exists?** A fixed bottom nav, a sticky header, a sidebar. These
  are collision surfaces.
- **What is the real mobile share?** Check analytics if reachable; otherwise ask rather
  than assume.

If any of these do not exist, that absence **is a finding** worth reporting - not a licence
to invent a parallel one mid-feature.

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

## 4. Mobile-first

Assume mobile is the majority until the project's own numbers say otherwise.

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

## 5. Accent consistency

**Each domain area gets exactly one accent, used consistently across cards, badges and
CTAs.** The specific map belongs to the project - find it, and if there isn't one,
establishing it is a decision to surface, not to make silently mid-feature.

**The tiebreaker** (resolves §2 vs §5): the app-wide primary CTA style wins for generic
and multi-area surfaces. Inside a section scoped to one area, that area's accent may carry
that section's own CTA - but never introduce a second treatment of the primary style.

## 6. Words are design material

- Name things by what people recognise, not how the system is built.
- A control says exactly what happens; the confirmation says it happened.
- Errors explain what went wrong and how to fix it.
- **Self-documenting UI:** a setting should state its consequence. If a toggle changes what
  a user is charged, how long their money is held, or who can see their work, say so next
  to the control - dynamically, with their actual numbers in it.

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
2. Run it and **look at it** at desktop and phone width. A screenshot you don't examine is
   not verification.
3. Confirm: no decorative pills, primitives reused (not copy-pasted), content above the
   fold, no horizontal overflow.
4. **On the phone-width shot specifically:** padding tight not bloaty, cards balanced not
   slender, nothing a placeholder for a feature that doesn't exist. Actually look at the
   cards - don't just check "it renders".

Proving it works end to end → `verify-for-real`.
