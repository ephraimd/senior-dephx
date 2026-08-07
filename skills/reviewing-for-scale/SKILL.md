---
name: reviewing-for-scale
description: Use when reviewing a change, a plan, or a diff for whether it survives production scale rather than whether it works - the lens a "it is tested and it works" pass skips. Fires when reviewing someone else's code or plan, on any list, search, report, or export path, on a new query or filter, on a report over a growing table, and on any claim that a data path is fine because the demo was fast. Covers whether a predicate can use an index, the hidden count query behind pagination, the real cost at N tenants and M rows, payload width versus what the screen needs, the same logic duplicated across services until the copies drift, tenant scope on every query, and unbounded inputs that let a cheap request trigger the widest scan.
---

# Reviewing For Scale

`verify-for-real` proves a change does what it says on the data in front of you.
`backend-shape` and `engineering-standards` shape how it is built. This is the pass that
asks a different question: **not "does it work" but "does it still work at the size this
system is going to be."**

Correctness is measured on the data on your screen. Scale is measured on the data you
will have. They are different questions, and a demo answers only the first. Your job as
the reviewer is to see the cost that is invisible in the UI: the query plan, the row
count, the second query nobody wrote on purpose, the twentieth tenant.

## The rule

**"Works" is measured on the data in front of you. "Scales" is measured on the data you
will have. Review the second one.** A feature that is fast on a seed database and fast in
the demo has proven nothing about the day one tenant has two hundred thousand rows and ten
of them act at once. The reviewer's job is to do that multiplication before production
does it for you.

## 1. Can an index actually serve this predicate?

**A query is only as fast as the index it can use, and several common shapes can use
none.** When that happens the engine reads every row in scope and checks them one by one,
which is fine on a seed table and fatal on a real one.

- A **leading-wildcard substring match** (looking for a term *anywhere* in a field) cannot
  use an ordinary sorted index. Neither can a **case-normalized match** with no matching
  functional index, a **function wrapped around the column** (normalize it, cast it, strip
  it, then compare), or an **OR across many columns**. Each forces a full scan of the rows
  the other filters left.
- Name the cost in the review, concretely: **O(rows in that tenant) per request, on a
  table that only grows.** Not "this could be slow" - "at two hundred thousand rows this
  reads all of them, every search."
- The tell: a search or filter whose speed you have only ever seen on a seed database, and
  an index list that has an entry for the column but of a kind that cannot serve *this*
  comparison. An index on the column is not the same as an index this query can use.

## 2. Count the queries, not just the query

**A paginated list usually runs a second query you did not write - an exact total over the
same predicate.** If that total is always computed, every page load pays the expensive scan
twice: once to fetch the page, once to count what the page is part of.

- Ask whether an exact total is even shown. Often the screen needs only "is there a next
  page," which one extra row answers for free - fetch one more than the page size and look
  at whether you got it.
- This is a property of the shared pagination helper, so it is easy to miss in a diff that
  looks like it only added a filter. The filter is where the cost lives; the count is where
  it doubles.

## 3. Put a number on it

**"It is fast" is not a measurement. Do the multiplication out loud.** Rows in scope, times
requests per minute, times tenants, on the one database the rest of the system also uses.

- A path that reads five hundred rows for your test account reads two hundred thousand for
  a real one, times every user who searches at once, while the background work that keeps
  the product running competes for the same connections.
- The number *is* the finding. "This scans the tenant twice per keystroke and the shared
  database is the bottleneck for every other feature" is a sentence a reader cannot wave
  away. "This might not scale" is one they can.

## 4. Return what the screen needs, not the whole object

**A list view that eagerly loads every nested relation is moving data no one will read.** A
picker needs an id and a label. An endpoint that returns the full record plus every joined
configuration for each of a hundred results has turned a lookup into a bulk export.

- Load the **summary** for the list, and the **detail** when a single row is chosen. The
  second fetch is cheap and only happens for the one row the user actually wanted.
- This is the failure that is easiest to see from the outside (the response is visibly
  huge) and it is usually the *smaller* cost. Fix it, but do not let a fat payload hide the
  un-indexed scan underneath it, which is worse and invisible.

## 5. One behavior, one implementation

**The same query copied into three places against one table is three things that must
change together and never do.** Find the source of truth. The copies have already drifted:
one has a filter the others lack, one excludes a status the others return, and the one you
are not looking at is the one serving wrong results.

- A **dead** copy is not harmless. It is the version someone wires up next, inheriting every
  flaw the source of truth has already fixed. Duplicated-and-unused is a trap with a delay
  on it, not a non-issue.
- The review action is not "make the copies match." It is "there should be one, and the
  others should be deleted or should call it." Matching three copies by hand just resets the
  drift clock.

## 6. Every query carries the whole tenant key

**A read scoped by half the tenant boundary returns another tenant's rows the day two
tenants share the other half.** "It only shows my data" on a single test account proves
nothing, because a single account cannot exhibit a cross-account leak.

- Check that the scope on the query is the *full* key the data model isolates on, not the
  most convenient half of it. A sibling endpoint that scopes by more than the one you are
  reviewing is the tell that the one you are reviewing is under-scoped.
- This is a correctness and a security finding, not a performance one, and it usually
  outranks everything else on this list. Rank it that way.

## 7. Bound the input, or the cheapest request buys the widest scan

**An unbounded input lets a trivial request become a full scan.** A one-character search, an
uncapped page size, a date range with no floor - each turns the cheapest thing a user can
type into the most expensive thing the database can do.

- A minimum search length, a maximum page size, a required range: these are not niceties.
  They are the line between a query and an outage triggered by a single keystroke.
- Check the input at the edge *and* the default in the helper. "The UI never sends more than
  fifty" is not a limit; it is a hope about a client you do not control.

## Proving a scale finding

A scale claim is a hypothesis until you have watched it be true, and `verify-for-real`
governs that: a green build and a fast demo prove neither the problem nor the fix.

- **The problem:** read the query plan on realistic data, or state plainly that you have
  not and are reasoning from the shape. A predicate that cannot use an index is a
  sound structural claim; the size of the pain is a measurement you either took or flagged
  as untaken.
- **The fix:** the read that used to scan should now seek, and the number from rule 3 should
  come out survivable. Until the plan changes, "it is fixed" is a wish. A migration that
  adds an index is not verified by the migration running - it is verified by the plan that
  uses it.

## Proposing the fix

A finding is half the review; the fix you recommend is the other half, and the failure here
is **leading with the most expensive correct answer.** For any fix, lay out the full
cost-and-quality spectrum before you recommend: the cheapest option that could work, what it
trades away, and the heavier options that buy back what it gave up.

- **Name the cheapest viable option first.** It is often a different behaviour, not a bigger
  machine - a narrower match, a coarser result, a bound the user will not notice. It may be
  all the situation needs, and it is the one the reader can ship this week. Lead with it, then
  show what it costs.
- **State what each option trades.** The cheap one usually spends quality or generality; the
  heavy one spends build time, write cost, or a migration. A recommendation with no stated
  tradeoff is a preference, not an analysis.
- **Some choices are the reader's, not yours** - especially when the cheap option changes a
  product behaviour rather than an implementation detail. Frame those as a decision with its
  consequences laid out, and recommend; do not decree.
- **Leading with the heaviest fix is its own anti-pattern.** It inflates the cost of acting,
  buries the option the reader would have taken, and reads as gold-plating. Earn the expensive
  answer by showing the cheap one falls short, not by reaching for it first.

## Reporting it

Separate **what ships broken today** (a leak, a query that already times out) from **what
breaks at scale** (fine now, fatal at N) from **what is duplicated and drifting**. On each,
name the concrete failure: the input, the row count, who feels it, and when.

- Rank by blast radius, worst first, and put the correctness and tenancy findings above the
  performance ones - a leak at ten rows beats a slow scan at two hundred thousand.
- Validate the parts of the change that are right, and say which of your findings are
  measured versus reasoned. A review that cries wolf on everything gets read like noise; one
  that separates the certain from the suspected gets acted on.

## Red flags

| You see... | It means |
|---|---|
| A search or filter matching a term anywhere in a field | Full scan; no ordinary index can serve it |
| A case-normalized or function-wrapped column in a WHERE | The index on that column cannot be used |
| A paginated list that always returns an exact total | The expensive predicate runs twice per page |
| "It is fast" with no row count behind it | Measured on seed data, not on a real tenant |
| A list endpoint eagerly loading every relation | Moving data the screen will never show |
| The same query in a second service against one table | Two truths that will drift, and already have |
| A dead endpoint that duplicates a live one | The version someone wires up next, with old bugs |
| A query scoped by part of the tenant key | A cross-tenant leak waiting for the second tenant |
| A required search field with minimum length one | The cheapest input triggers the widest scan |
| A scale verdict with no query plan behind it | A hypothesis wearing a conclusion's clothes |
| A recommended fix with no cheaper option beside it | The cost/quality spectrum was never laid out |
