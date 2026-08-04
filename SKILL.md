---
name: Pathpoint
description:
    Manage Pathpoint risks, quotes, and submissions. Use when the user wants to add, update, or
    delete quotes, browse recent risks, modify submission fields, clone a submission, search for
    risks, or perform any operation on the Pathpoint insurance platform.
---

# Pathpoint Operations

Supplement the `pathpoint` MCP server tools with conversational guidance for non-technical users.
Ask questions in plain English, one at a time. Never show raw JSON, GraphQL, or internal IDs to the
user.

## Interaction Pattern

Every operation follows the same shape:

1. **Login** — call `get_login_status`. If not logged in, call the `login` MCP tool to get the exact
   `p login --endpoint <env>` command for the user to run in their terminal. The terminal flow opens
   a localhost browser form so the password never appears in chat — never accept a password from the
   user in conversation. After they complete it, call `get_login_status` again to confirm.
2. **Find the risk** — ask for a UUID or company name, then call `search_risk`. If the user just
   wants to browse recent activity, use `list_risks` instead. If multiple results, present a
   numbered list and let the user pick. Confirm with `get_risk` to show full details.
3. **Gather intent** — determine what the user wants to do and collect the necessary inputs (see
   domain knowledge below).
4. **Confirm** — show a human-readable summary of what will happen. Wait for approval.
5. **Execute** — call the appropriate MCP tool.
6. **Verify** — call `get_risk` again and report what changed.

## Not every tool is loaded (`list_toolsets`, `enable_toolset`)

Only the **core** group loads by default — everything in "The everyday loop" below. Six specialist
groups are hidden from the tool list to keep the context payload small:

| Group          | What is in it                                                                       |
| -------------- | ----------------------------------------------------------------------------------- |
| `endorsements` | Changing or cancelling a BOUND policy, and the ops side that accepts or declines it |
| `policy`       | Cancel/reinstate a policy, non-renewal, undo a mistaken bind, carrier inspections   |
| `properties`   | Adding, duplicating and deleting buildings on a multi-location risk                 |
| `admin`        | Agency-network and agency records (commissions), your own profile and sharing scope |
| `claims`       | Loss-history rows on a building, and flagging a new claim against an issued quote   |
| `hazard`       | Ordering third-party hazard data (wildfire scores) — internal ops/QA work           |

**If a Pathpoint capability looks missing, call `list_toolsets` before concluding it does not
exist**, then `enable_toolset` to load the group for this session. Never improvise a workaround (or
tell the user to go to the app) for a tool that is merely hidden. If the newly loaded tools still do
not appear on the next turn, the MCP client is not honouring tool-list changes — tell the user to
add `--toolsets <name>` (or `--toolsets all`) to the `p mcp-serve` args in their MCP config, or set
`$P_MCP_TOOLSETS`, and restart it.

Reading a risk's buildings (`list_properties`) is core, so per-location answers can still be written
with `modify_submission` without loading the properties group.

## The everyday loop

### Finding risks (`search_risk` vs `list_risks`)

- `search_risk` — use when the user names a specific company or knows the UUID. Accepts a single
  query string; matches named insured (case-insensitive substring) or policy number, most recently
  updated first, at most 10 results. A blank query is refused rather than run: an empty search
  returns unfiltered recent risks that look exactly like confident matches. If the results do not
  contain the search term the tool says so — relay that caveat instead of presenting them as hits.
- `list_risks` — use for "show me my recent submissions" or "what's in the queue". Optionally filter
  by status (`DRAFT`, `SUBMITTED`, `QUOTED`, `BOUND`, `ISSUED`, `DECLINED`, `REFERRED`). Defaults to
  the 20 most recent; max 50.
- `list_recoverable_drafts` — use for "did I leave something half-finished?". `list_risks` does not
  surface never-submitted drafts; this does, with percent complete and product. Resume one with
  `get_submission_questions` → `modify_submission` → `submit_risk`.

    **The default window excludes today.** `days_ago_start` is the OLDER bound and must be strictly
    GREATER than `days_ago_end` — an equal pair asks for a single instant and matches nothing, so it
    is refused rather than returning a misleading empty list. The defaults (7 and 1) mean "created
    between 7 days and 1 day ago", so a draft started this morning does not appear. Pass
    `days_ago_end: 0` to include the last 24 hours. Add `include_agency: true` to also see
    agency-shared drafts owned by colleagues. It is expensive — it rebuilds the question tree for
    every draft and caps at 100 rows — so call it once, not in a loop. A row showing 0% and a named
    insured of "New Submission" may be a genuinely empty draft or a backend hiccup; the tool says so
    rather than reporting 0% as fact.

### Reading a risk (`get_risk`, `get_risk_activity`, `get_action_items`)

- `get_risk` — full details: status, product, dates, submissions, quotes. The verification step
  after every write.
- `get_risk_activity` — use for "what's the latest on this risk?", "any notes from the team?", or
  before summarizing a risk's state. Returns notes, submissions, quote letters, bind requests, and
  declines, most recent first. Attached files show by name only — use `list_risk_files` when the
  user wants a download link.
- `get_action_items` — use for "what's on my plate?", "anything I need to do?", or as a morning
  round-up. Defaults to the user's own risks; pass `scope: AGENCY` when they ask about their whole
  agency. Follow up on a specific item with `get_risk` / `get_risk_activity`.

### Leaving a note (`add_risk_note`)

The write side of `get_risk_activity`. Use it for "leave a note on this risk" or to record what was
discussed with the insured. Takes `risk_id`, `quote_id` and `text`.

**`quote_id` is required, and it is doing real work.** The API authorizes this write against the
quote, and the tool derives the note's submission from that same quote — which is what stops a note
landing on the wrong risk. Accepts a quote number, EID or UUID.

**Permanent and append-only.** A note cannot be edited or deleted by any tool or by the app, calling
twice leaves two notes, and it is visible to the owning agency and to Pathpoint staff (it may also
notify them). So read `get_risk_activity` first rather than retrying a call whose outcome you are
unsure of. The entry is always a `COMMENT`; the tool deliberately exposes no way to write the
lifecycle activity types (`BOUND`, `ISSUED`, `SUBMITTED` and friends) because those are the server's
to write and minting one would fake a state change in the audit trail.

### Discovering fields (`get_submission_questions`, then `list_fields`)

`get_submission_questions` is the discovery step. Use it whenever you intend to write: it returns
the live question set with current labels, answer types, allowed options, prefills, required-field
progress and validation errors, so you can go straight to `modify_submission`. Call `list_fields`
only for a quick read-back of stored labels and values outside that flow, or with a specific `view`
to narrow results (e.g. `ORGANIZATION_INFORMATION` for address/revenue, `COVERAGE_OPTIONS` for
dates/limits). (`list_fields`' own tool description offers itself as the discovery step — prefer
`get_submission_questions` anyway; it is the one that reports options, progress and errors.)

Either way, fields vary by product type, and a draft with no product assigned may have no fields at
all:

- If `get_risk` shows "Product: (none assigned)", the risk needs a product type before fields can be
  modified.
- If `list_fields` returns no fields, tell the user and suggest checking the product assignment.

**Incomplete results.** Both tools may return a result that starts with
`WARNING — THIS RESULT IS INCOMPLETE`. That means the server rejected one or more submission views
this build of `p` asks for, so the listing is missing whole sections. Never conclude from a
banner-carrying result that a field or question does not exist, and never tell the user a value
cannot be set — say the tool and the server are out of sync, and work from the views that did come
back.

### Modifying submissions (`modify_submission`)

The `modify_submission` tool accepts human-readable field labels (e.g. "Organization Name", "Annual
Revenue") and resolves them internally. Use the exact labels from `get_submission_questions` (or
`list_fields`) to avoid mismatches.

If the user pastes unstructured data (broker email, correction form), extract field changes, verify
the labels, and confirm before executing.

After a write, the tool reports any questions that appeared or disappeared as a result (the form is
conditional) plus how many required answers remain — relay new questions to the user instead of
re-listing everything. See "Product-specific answer rules" below for class codes, exposures, excess
underlying limits, value types, and multi-building path prefixes.

### Starting a new submission conversationally (`create_risk` → `get_submission_questions` loop)

The from-scratch entry point — use when there's no similar risk to clone. The question set is
dynamic: answers reveal new questions, so work the loop below rather than trying to collect
everything up front.

1. **Intake.** Ask what coverage the client needs and map it to a product id (`cyber`, `cglV2`,
   `monolinePropertyV2`, `mpl`, …); when unsure, check an existing risk of the same flavor with
   `get_risk`. Then invite everything at once: "Paste whatever you have — broker email, notes,
   details — and attach any ACORDs or supplementals."
2. **Create** the risk with `create_risk`, then immediately call `get_submission_questions` to learn
   the actual question labels, types, and allowed options. For property-carrying coverages
   (`package*`, `monolineProperty*`), pass `tenancy_types` at creation — ask what occupies the
   building, find the canonical strings with `search_tenancy_types`, and pass them in the
   `create_risk` call. Property raters hard-require an occupancy, and some package products
   (`packageRestaurants` at least) never serve an occupancy question in the submission flow — so
   creation is the only conversational chance to set it there, and a package risk created without
   one is declined by every property market at submit. (`monolineProperty*` also serves a "Tenant
   type" question that can be set later.) Pass `class_codes` at creation for GL-family products too
   — some verticals (`cglManufacturing` at least) never serve a class-of-business picker in the
   flow, yet their raters hard-require the risk-level class codes: a risk created without them is
   declined by every market with no appetite reason given. For products that do serve a picker
   (`cglV2`, `cglVacants`), the preselect just skips it. Heed any warning in the create_risk
   response about preselects the server did not apply.
3. **Files.** Upload each file with `upload_risk_file` and `extract: true`. Extraction runs in the
   background (about a minute) — keep collecting info meanwhile, and check `get_extraction_status`
   before the review step. If extraction fails, proceed without prefills and ask instead.
4. **Extract from text yourself.** Map what the user pasted onto the real question labels. Only use
   values the user actually provided — never guess or invent an answer, especially for underwriting
   questions.
5. **Batch review.** Present one plain-English summary of every value you intend to write, grouped
   by page, marking where each came from ("from your ACORD", "from your email"). Call out
   high-stakes fields individually: effective date, annual revenue, class of business. Get one
   approval, then write everything with a single `modify_submission` call.
6. **Follow the cascade.** The write response reports newly appeared questions — relay them
   conversationally ("that unlocked 3 questions about your kitchen operations"). Ask remaining
   questions a few at a time, grouped by page, offering allowed options verbatim. Answers can be
   option text — the tool maps them to values. For tenancy-type questions (the type hint reads
   "tenancy type"), ask what actually occupies the building, use `search_tenancy_types` to find
   candidates, offer the top matches conversationally, and write the exact returned value (for
   multiple tenancies, one canonical string per line) — free text fails silently at rating. On a
   risk that already has answers or uploaded documents, `get_recommended_tenancy_types` can suggest
   tenancies from the risk's own data first; it returns bare codes, so still resolve each one
   through `search_tenancy_types` to get the canonical string before writing it.
7. **Loop** steps 5–6 until `get_submission_questions` reports all required questions answered and
   no validation errors. Mid-flow corrections ("actually the effective date is June 1") are just
   another `modify_submission` call.
8. **Submit** via the `submit_risk` flow below: summary, explicit confirmation, then report which
   markets it went to and any instant quotes or declines.

### Checking appetite before submitting (`get_appetite`)

Asks the PALMS rules engine which carriers want this risk and, when they don't, why not — four
buckets per coverage (MAY_PROCEED, WILL_REFER, MIDDLE_MARKET_ELIGIBLE, WILL_DECLINE) with
per-carrier reasons in plain English. It is the only way to see a decline reason BEFORE submitting,
and the fastest explanation for "why did this come back declined". Run it after `modify_submission`
and before `submit_risk` / `quote_risk`, then again after edits to confirm a fix landed. A bundle
risk fans out to one set of buckets per child coverage.

Three things not to get wrong when relaying the result:

- **Absence is not approval.** A carrier is dropped from all four buckets when it is not configured
  to write that product, or when PALMS matched it but returned no reasons. A carrier that is not
  listed has no verdict here — never report it as "no objection".
- **All buckets empty means no verdict, not a decline.** Say the engine returned nothing for this
  risk; do not tell the user every market declined.
- **It is not the submittable-markets list.** `resubmit_risk` validates its `markets` argument
  against a static config lookup answering "which carriers write this product". `get_appetite`
  answers "which carriers want THIS risk", recomputed from the current draft answers on every call.
  Conflating them either submits into a decline or skips a market that would have quoted.

### Submitting a risk (`submit_risk`)

Submits a drafted risk to its markets for quoting — the same action as the Submit button in the app.
Before calling:

1. Confirm required fields are filled (`get_submission_questions`); fix gaps with
   `modify_submission`.
2. Show the user a summary of the risk (`get_risk`) and confirm they want to submit.

Validation failures come back listing the missing fields — relay them in plain English and offer to
fill them. After a successful submit, the tool returns the refreshed risk summary; report which
markets it went to and any instant quotes or declines.

### Choosing markets (`select_markets`)

Steers which markets a not-yet-submitted risk goes to. Accepts carrier names ("Kinsale") or market
UUIDs, and takes `add_markets`, `remove_markets`, or both in one call.

**It is write-only.** No query in the API returns a risk's current market selection, so this cannot
show what is selected now and cannot diff before and after — and its success response is not proof
the rows changed. Never tell the user you have verified the selection. A market may not appear in
both lists: the server applies adds before removes, so it would silently net to removed, and the
tool refuses that rather than guessing.

Adds are idempotent and removing a market that was not selected does nothing, so a repeated call is
harmless. This only affects where a risk goes **next** — it does not recall, cancel or unsend
anything already submitted. Use `resubmit_risk` to go back out to markets.

### Quoting (`quote_risk`)

The tool routes limits into the correct typed input automatically based on the risk's product. You
usually don't need to pass `product` — it's inferred from the risk. Pass it only if the user
explicitly overrides (rare).

Determine the product type from the risk, then ask for the right limits:

| Product                      | Limits to ask                                                                                        |
| ---------------------------- | ---------------------------------------------------------------------------------------------------- |
| Cyber                        | `aggregate_limit`, `per_occurrence_limit`, `retention`                                               |
| GL (CGL)                     | `aggregate_limit`, `per_occurrence_limit`, `products_completed_ops`                                  |
| Package                      | Same as GL — package products resolve to a general-liability line server-side                        |
| Excess                       | `aggregate_limit`, `per_occurrence_limit`, `products_completed_ops`                                  |
| Property / Monoline Property | `aggregate_limit` (use the flat limit; other property fields live in the application, not the quote) |

Two product families cannot be quoted through these tools at all, and the tool refuses with an
explanation rather than dropping the limits: a **bundle** has no single line of insurance (quote its
individual child risks instead), and **mpl** has no line-of-insurance mapping on the server at all
(use the app). Relay the explanation — retrying with different limits will not help.

Always ask:

- **Premium** (required)
- **Carrier** — can be picked from existing submissions or named freely
- **Effective/expiration dates** — default from the risk, confirm with user
- **Quote number** — optional
- **Fees** — agency, company, stamping, inspection (ask once, skip if none)
- **TRIA** — optional
- **Wind** — `includes_wind` (does the quote cover wind) and `est_cost_wind` (the wind portion of
  the premium), both optional
- **Admitted or non-admitted** — default non-admitted (omit `admitted` to keep the default). Pass
  `admitted: true` for admitted.
- **Comment** — optional

### Identifying a quote

Tools that take `quote_identifier` accept a quote number, an EID, or a UUID. **Quote numbers are not
unique.** When a number matches more than one quote the tool lists the candidates and stops instead
of picking one — show the user the list and pass the EID or UUID of the one they mean. Re-sending
the same quote number will just fail again.

### Viewing quote details (`get_quote`)

When the user asks about a specific quote, use `get_quote` to show the full picture — cost breakdown
(premium, fees, taxes), limits, wind coverage and its estimated cost, subjectivities, and status
flags. If the user picks a quote from the `get_risk` summary, use the EID shown there.

### Updating quotes (`update_quote`)

Show the existing quotes from `get_risk` as a numbered list with carrier, quote number, premium, and
status. Let the user pick one. Use `get_quote` to show full current details, then ask what to
change. Accept free-form input — "change premium to $4,200 and add a $500 agency fee" — and map to
the tool parameters.

Limit parameters are routed by product the same way as `quote_risk`, including package products. To
flip an admitted quote to non-admitted, pass `admitted: false` explicitly (omitting it leaves the
current value alone). Wind behaves the same way: pass `includes_wind: false` explicitly to drop wind
coverage, and `est_cost_wind: 0` explicitly to clear a previously-set wind cost. Both are sent as
written — unlike the fee parameters, where a 0 reads as "not supplied" and is omitted — so omitting
them is what leaves the current values alone.

Show a before/after summary before executing.

### Bind readiness (`check_bind_readiness`)

Run before `request_bind` or whenever the user asks "can I bind this yet?" — it reports validation
blockers and incomplete subjectivities without changing anything, and names the tool that clears
each one (`upload_subjectivity_file` for FILES, `answer_subjectivity` for TEXT / DATE / CHECKBOX /
CONTACT_INFO). Walk the user through fixing each blocker, then re-check. A missing quote letter
comes back as a `QUOTE_FILE_MISSING` blocker — that one is fixed with `attach_quote_file`, not in
the app.

### Requesting to bind (`request_bind`)

The conversion action — tells the Pathpoint team the agent wants to bind a quote. Identify the quote
the same way as `update_quote` (number, EID or UUID, plus `risk_id`). The tool selects the quote on
the risk automatically if it isn't already selected.

Always confirm before calling — show carrier, quote number, premium, and effective dates, and get an
explicit "yes". After requesting, check `list_subjectivities` for outstanding requirements and tell
the user what's still needed to complete the bind.

Optional `licensed_agent_email` routes the bind through a specific licensed agent, for agencies that
require one. If the quote carries a `SELECT_LICENSED_AGENT` subjectivity, that is the signal to ask
who the licensed agent is; resolve the exact address with `list_agency_users` and pass it here.

Two things it won't do on its own:

- It refuses to run on a quote with no quote letter ("Quote letter is not ready" /
  `QUOTE_FILE_MISSING`). Manual quotes made with `quote_risk` never auto-generate one — attach a PDF
  with `attach_quote_file` (`file_type: QUOTE_LETTER`) and retry.
- It does not put the quote in front of Pathpoint ops. Follow it with `create_bind_request_task`.

### Ops bind queue (`create_bind_request_task`)

`request_bind` runs the bind validations and notifies the team, but it does not create the ops task,
so a bind requested through `request_bind` alone never reaches the queue ops works off. Call
`create_bind_request_task` afterwards to complete the handoff — pass `risk_id` plus
`quote_identifier` (quote number, EID, or UUID). It is idempotent: when a task is already queued it
reports that one and creates nothing. `cancel_bind_request` withdraws it.

## Rules that apply to every tool

**Writing to production.** Every tool that changes anything refuses to run against a prod session
unless it is called with `confirm_prod: true`. Treat the refusal as designed: state in plain English
what is about to change, get an explicit "yes", then re-call with the flag. Never set it
pre-emptively on a call the user hasn't approved.

**A timeout means UNKNOWN, not failed.** Long operations get longer budgets — 300s for bind, issue
and document generation, 120s for quoting and submission, 30s for everything else. If one times out,
the server may well have completed it after the client stopped waiting. Do not report a failure and
do not retry blindly: re-read the object first (`check_bind_readiness` or `get_quote` after a bind,
`get_risk` otherwise) and retry only if it did not take effect. Never retry a bind on a timeout
without checking — that is how a policy gets bound twice.

**Server errors.** Common server rejections come back with a plain-English explanation ahead of the
raw message. Relay the explanation, not the GraphQL text.

**Download links.** `list_risk_files` and `get_quote_documents` return names, types and sizes only;
presigned URLs are omitted unless you pass `include_urls: true`. List first, then re-call with the
flag once you know which document the user actually wants.

## Product-specific answer rules

### GL / class-of-business products (cglV2 and friends)

GL-family submissions classify the business with 5-digit class codes instead of (or alongside)
tenancies:

- **Class of business page.** The vertical picker (type hint mentions class codes, e.g. "What type
  of contractor is your applicant?") stores comma-separated 5-digit codes. On a risk that already
  has answers or uploaded documents, try `get_recommended_class_codes` first — it suggests codes
  from that risk's own data, ranked by confidence, with no search wording needed. Otherwise (or if
  it comes back empty) ask what the business actually does and use `search_class_codes` to find
  candidates. Either way, offer the top matches in plain English, then write the code(s)
  comma-separated (e.g. `"91560,91580"`). Free text fails classification silently at rating — never
  invent codes.

    Both recommendation tools only return matches scoring 0.8 or above, so **an empty result is
    ambiguous** — no completed aggregation job, or nothing confident enough (and for tenancy, a
    third cause: the recommended tenancy is no longer in the catalog and was silently dropped). It
    never means the risk cannot be classified; fall back to keyword search rather than reporting a
    dead end.

- **Tenancy recommendations.** `get_recommended_tenancy_types` is the tenancy equivalent, and has
  one extra trap: it returns tenancy **codes only**. Resolve each code to the full canonical
  `"<code>: <description>"` string with `search_tenancy_types` before writing it — a bare code fails
  tenancy parsing silently at rating, exactly like an invented class code.
- **Per-location exposures.** Each location's "Class of business and exposure values" question
  stores a JSON array with one entry per selected class code:
  `[{"id":"91560","selected":true,"value":"250000"}]` — `selected` marks the classes operating at
  that location, `value` is the exposure amount for that class. The amount's basis depends on the
  class code AND the product (payroll for contractor trades, gross sales for retail/restaurants,
  area for some premises classes, acres for vacant land) — the SAME code can rate on a different
  basis per product: 61212 takes annual rents on `cglLRO` but building AREA on
  `lroExcessStandalone`, where a rents-sized number reads as square footage and hard-declines on
  appetite. Ask the user for the figure that fits the class and product. Restaurant classes split
  food and liquor sales as two newline-separated numbers in one `value` string (`"400000\n50000"`).
- **Subcontractors page (contractors).** "Does applicant hire subcontractors…" is a yes/no; a yes
  cascades follow-ups including "What type of work is subcontracted?". That question does NOT take
  the trade's own class code — it only accepts the "Contractors – Subcontracted Work" codes listed
  in its type hint (91581/91583/91585/91591, by what the subcontractors build). Writing a trade code
  there silently adds a phantom class to the submission and EXPOSURES starts demanding an exposure
  for it.
- **Exposure follow-through.** Every class code selected anywhere (vertical picker AND subcontracted
  work) must get an entry in each location's exposure JSON — validation errors name any code left
  without one.

### Excess standalone products (`contractorsExcessStandalone`, `lroExcessStandalone`)

Excess submissions add an underlying-policy block: carrier (a huge validated select — search it by
what the user says, offer close matches), A.M. Best confirmation, underlying premium, dates, and
limits. Two of the limit questions ("General Aggregate Limit", "Products-Completed Operations
Limit") list NO options — they store integers, so write plain numbers (`2000000`), never
`"$2,000,000"` text (it passes validation but fails server-side). Their siblings that do list
options ("Per Occurrence Limit") take the option text as usual.

### Value types and look-alike checkbox groups

- Write numbers as numbers: year, count, and money questions reject numeric strings server-side, and
  a `modify_submission` batch is all-or-nothing — one bad value rejects every change in the call.
- When several checkbox groups share the same truncated header (e.g. three different "Select all of
  the following that apply to any location: › None of the above" rows), a colliding write errors and
  lists the full disambiguated paths — copy one back verbatim, including any `:_suffix` in the group
  text. If a bare write silently satisfies only one of the look-alike groups, the progress counts
  reveal the ones still missing.

### Multi-location risks (`list_properties`, `add_property`, `duplicate_property`, `delete_property`)

`create_risk` seeds exactly one property, so a second building or address only exists if you create
it. `list_properties` is core; the three write tools live in the `properties` toolset.

- `list_properties` — every building on the risk with its `property_id`, name, address, and the
  exact field-path prefix `modify_submission` needs for it. No query returns property ids, so this
  is the only way to find the id the other two tools take.
- `add_property` — a NEW location (a different address). Pass the address in the same call if you
  have it, but all of street, city, state and ZIP together or none at all. The new building is
  auto-named "Building N" and has **no Location Number**, which most property products ask for as a
  required question — set it afterwards with `modify_submission`.
- `duplicate_property` — a SECOND BUILDING AT THE SAME ADDRESS. Copies every answer including the
  address and Location Number, clears the building description, and derives the portal's own next
  name (max+1 over buildings sharing the source's base name) unless you pass one.
- `delete_property` — removes a building and everything stored on it. A risk must keep at least one,
  so deleting the last is refused.

**Addressing a specific building.** Once a risk has more than one, a bare label like "Building
Limit" is ambiguous and gets rejected. Prefix it with the building's ordinal path, which differs per
view — `Property 2 › Building Limit` in PROPERTY_DETAILS, `Location 2 › Address` in EXPOSURES.
`list_properties` prints the exact prefix for each one.

**The numbering shifts.** Any add, duplicate or delete renumbers the remaining buildings (the server
decrements Location Numbers above a deleted one), so every previously copied `Property N` /
`Location N` prefix may now point at a different building. Re-read `list_properties` (or
`get_submission_questions`) after any of the three before the next write — never reuse a prefix from
before the change.

"Three buildings at two addresses" is `add_property` for the second address, then
`duplicate_property` for the extra building.

### Verifying an address (`search_addresses`, `set_property_geocode`)

An address written with `modify_submission` is stored exactly as typed. Nothing validates it, and
nothing derives the county or the coordinates that carrier appetite and hazard scoring read. Resolve
it first, in this order: `search_addresses` → confirm the candidate with the user →
`modify_submission` for street/city/state/ZIP → `set_property_geocode`.

- `search_addresses` — AWS address autocomplete. Needs a street number and a street name; a bare
  city is refused locally, the same rule the web client applies. Returns full candidates each
  carrying a `place_id`. **An empty result is ambiguous** — the server swallows AWS errors and
  returns nothing — so it is never proof the address is wrong.
- `set_property_geocode` — takes a `place_id` plus the `entity_id` of the property (from
  `list_properties`) and stores latitude, longitude and county on it, returning the county.

Two things about `set_property_geocode` that its name does not tell you. It **writes**, even though
the underlying API call is shaped like a read, so it takes `confirm_prod` on prod. And `entity_id`
is not optional: without it the server returns nulls and writes nothing at all, silently. The write
is best-effort — failures, including a permissions failure on the property, are logged and discarded
server-side while the county still comes back — so treat success as "the lookup happened", not "the
values persisted". Re-read with `list_fields` if it matters.

## Working the rest of the risk

### Selecting a quote & TRIA (`select_quote`, `set_tria`)

`select_quote` marks the quote the agent intends to bind and generates its bind checklist — use it
when the user picks a quote but isn't ready to request bind (request_bind selects automatically).
`set_tria` toggles terrorism coverage on a quote; premium and fees change, so show the updated
`get_quote` cost afterwards.

### Subjectivities (`list_subjectivities`, `answer_subjectivity`, `upload_subjectivity_file`)

Subjectivities are the bind requirements on a quote. `list_subjectivities` shows them with EIDs,
response types, and completion status — by default just the selected quote's (pass
`all_quotes: true` for everything).

To answer one, pass `answer_subjectivity` the EID (or an unambiguous title fragment) plus `text`
and/or `mark_complete: true`. Match the response type:

- **TEXT / CONTACT_INFO** — collect the answer in conversation, save it as `text`, mark complete.
- **FILES** — use `upload_subjectivity_file` with a local file path; it uploads, attaches, and marks
  the subjectivity complete in one step. Confirm the file is the right document first.
- **CHECKBOX / DATE** — confirm with the user, then `mark_complete: true`.

Read back the saved answer before marking complete when the answer matters (payment info, inspection
contacts).

### The insured contact (`get_insured_contact`, `set_insured_contact`)

The named person Pathpoint emails the signing documents to, saved against a quote. It is the real
record: writing contact JSON into a CONTACT_INFO subjectivity sets the subjectivity text but leaves
this empty, and the Inspection Contact / Insured Pay / Audit Contact answers are fed from here. Both
tools take the quote UUID plus the risk UUID — an EID or quote number is rejected by the API.

- `get_insured_contact` — the saved contact, any contacts on the risk's other quotes, and the
  prefill candidates the app would offer. Having none is a normal state, not an error: the form only
  shipped in May 2025, so older risks never collected one.
- `set_insured_contact` — saves all four fields (first name, last name, email, US phone) at once;
  there is no partial update. **Replacing a contact that already exists invalidates the e-sign
  packet**: issued signing URLs expire, e-signed subjectivities revert to incomplete, and prefilled
  manual-sign documents are voided, so documents must be regenerated and re-sent to the insured. The
  tool performs those invalidations itself and says so. Creating a contact where there was none has
  no such effect. Warn the user before replacing, and re-check the Inspection Contact / Insured Pay
  / Audit Contact subjectivities afterwards — this tool does not rewrite them the way the app does.

### Deleting quotes (`delete_quote`)

This is a soft delete — the quote is marked deleted and hidden from normal queries, but the action
is not typically reversible from the UI. Always confirm with the user before calling the tool:

```
Delete quote KIN-001 from Acme Cyber Corp (Kinsale, $4,200)?
This cannot be undone from the app.
```

Only call `delete_quote` after an explicit "yes". Never default to delete when the user says
"remove" or "cancel" — ask if they mean delete vs. unbind vs. decline.

### Canceling a bind request (`cancel_bind_request`)

The undo for `request_bind` — use when the client backs out or the wrong quote was requested. Always
collect a reason (it goes to the Pathpoint team) and confirm before calling.

### Changing policy dates (`update_policy_dates`)

The fix when a quoted risk's effective date has slipped — the classic blocker between "quote
selected" and "bind requested". Writes the new effective/expiration dates on both the application
and the quote, recalculates the quote's grace period, and queues a Novidea update. Three things to
keep straight:

- **It does not re-rate.** Premium and terms are untouched; for a large date move the carrier may
  require a fresh quote (`resubmit_risk`) instead. Before any quote exists this tool is the wrong
  one anyway — pre-quote, the effective date is submission data and feeds rating, so use
  `modify_submission`.
- Both dates are required. Don't silently assume an annual term: confirm the expiration with the
  user (most policies are effective + 1 year, but not all).
- Documents generated earlier (quote letter, ACORDs) keep the old dates until regenerated.

It operates on the risk's **selected quote only** — the mutation rewrites the application's policy
dates along with the quote's, so pointing it at a non-selected quote would leave the application and
the quote being bound disagreeing. If nothing is selected yet, `select_quote` first.
`quote_identifier` is accepted as confirmation but must name the selected quote. Bound quotes are
refused outright: those dates belong to an active policy, and changing them is endorsement work
(`create_endorsement_request`), not a pre-bind fix.

### Resubmitting (`resubmit_risk`)

Use after quotes expire, markets decline, or the submission changed — "get me fresh quotes" or
"resubmit to Vave". Targets specific carriers by name or all submittable markets when omitted.
Carrier names are validated against the risk's submittable markets and the error lists the options,
so on a mismatch just relay the choices.

### Declining a submission (`decline_submission`)

Records a manual decline on a market's behalf with a free-text reason, which shows on the activity
log. Identify the submission by its UUID, or by `risk_id` plus the carrier's display name (matched
case-insensitively as a substring). On a package risk, `decline_all_lines: true` also declines every
sibling negotiation that shares this market across the child lines. Confirm the carrier and the
reason with the user first — this is what the agent will see as the market's answer.

### Renewals (`renew_risk`, `get_renewal_changes`)

Use `renew_risk` when the user wants to renew an expiring policy/term. It creates a renewal draft
linked to the original and carries data forward — it refuses to duplicate an existing renewal and
reports it instead. After creating, review dates and exposures with the user, apply updates, then
`submit_risk`.

`get_renewal_changes` shows field-by-field diffs against the expiring term with who changed what and
when — useful for "what's different on the renewal?" before submitting it.

### Cloning submissions (`clone_submission`)

Show a summary of the source risk. Ask:

1. "Do you want to change anything on the new submission?" — collect changes as field/value pairs
2. "Submit for quoting right away, or leave as draft?"

The tool handles creating the risk, copying values, applying changes, and optionally submitting —
all in one call. If the source risk has no product assigned, clone will fail with a clear error;
have the user fix that on the source before retrying.

### Excess cross-sale (`create_excess_from_quote`)

Turns an existing quote on an underlying GL risk into a standalone excess (umbrella) submission. It
creates a NEW risk: the underlying risk's answers are cloned onto the excess product and the
underlying-policy block (carrier, premium, occurrence/aggregate/PCO/personal-injury limits, dates,
operations state and ZIP) is seeded from the quote, so it starts mostly filled in. The original risk
and quote are untouched. Follow it with `get_submission_questions` on the new risk, fill the gaps
with `modify_submission`, then `submit_risk`.

Eligibility is the server's call: contractors GL (`cglV2`) becomes `contractorsExcessStandalone`,
LRO (`cglLRO` / `packageLRO`) becomes `lroExcessStandalone`, and a bundle qualifies through
whichever of those it offers. Any other coverage comes back with an error naming the coverage — that
error is the answer, so relay it rather than retrying.

### Sharing & ownership (`share_risk`, `set_risk_owner`)

- `share_risk` — "share with my team" → scope AGENCY; "make this private" → PERSONAL.
- `set_risk_owner` — hand a submission to a teammate by email. Confirm the email before calling; the
  user must already exist in Pathpoint.

### Agency directory (`list_agency_users`)

Lists names and emails at the user's agency. Use it to resolve "assign this to Sarah" into an exact
email for `set_risk_owner`, or to pick a licensed agent for `request_bind`.

## Files & documents

### Risk files (`upload_risk_file`, `delete_risk_file`, `list_risk_files`)

`upload_risk_file` attaches a local file (loss runs, supplementals, ACORDs, signed docs) to a risk —
ask for the file's path, confirm name and target risk, then upload and verify with
`list_risk_files`. For submission documents (ACORDs, supplementals), pass `extract: true` so
extracted values prefill the application — track progress with `get_extraction_status`.
`delete_risk_file` is a soft remove by file EID; confirm before deleting, same as quotes.

`list_risk_files` returns names, types and sizes; add `include_urls: true` only when the user wants
to download something.

### Loss runs (`request_loss_runs`)

For bound/issued risks when the user asks for loss runs. The documents arrive asynchronously — check
`list_risk_files` later rather than promising instant results.

### Quote documents (`get_quote_documents`)

Use when the user wants the quote letter, proposal, invoice, binder, or policy paperwork. Returns
the document list; pass `include_urls: true` to get presigned download links, and share the link,
not the raw URL string dump. If nothing is attached yet, say so; quote letters can take a few
minutes to generate after quoting.

### Attaching quote documents (`attach_quote_file`)

The write side of `get_quote_documents` — uploads a local file and attaches it to a quote as a typed
document. Admin-only: the underlying mutation requires `GLOBAL_ACCESS_PROTECTED_RESOURCE`.

| Parameter      | Required | Notes                                                                                                                                                                                                                                                 |
| -------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `quote_id`     | yes      | Quote UUID or EID. A quote number is not accepted — resolve it with `get_quote` first                                                                                                                                                                 |
| `file_path`    | yes      | Absolute path of the local file                                                                                                                                                                                                                       |
| `file_type`    | yes      | `APPLICATION`, `COVER_LETTER`, `POLICY_DOC`, `QUOTE_LETTER`, `SIGNED_APP_FORM`, `SUPPLEMENTAL_DOC`, `BINDER`, `INVOICE`, `LOSS_RUNS_DOC`, `NOTICE_OF_POLICY_CANCELLATION`, `NOTICE_OF_REINSTATEMENT`, `CANCELLATION_INVOICE`, `REINSTATEMENT_INVOICE` |
| `file_name`    | no       | Override the stored name (defaults to the file's base name)                                                                                                                                                                                           |
| `confirm_prod` | on prod  | `true` is required when the session points at prod                                                                                                                                                                                                    |

**The bind unblock.** Manual quotes created with `quote_risk` never auto-generate a quote letter, so
`request_bind` hard-fails with "Quote letter is not ready" (`QUOTE_FILE_MISSING`) until one exists.
Attaching a `QUOTE_LETTER` sets the quote's letter pointer and clears the blocker:

```
quote_risk → attach_quote_file (QUOTE_LETTER) → check_bind_readiness → request_bind → create_bind_request_task
```

Re-attaching replaces that slot — the previous file stays on the risk, only the quote's pointer
moves. Verify with `get_quote_documents`.

## After the bind: servicing a policy (policy toolset)

Load with `enable_toolset` — these six tools are hidden by default.

### Inspections (`get_inspection_status`, `upload_proof_of_inspection`)

Inspection is a mandatory timeline stage between Payment and Policy for any policy bound on a quote
carrying an inspection fee.

- `get_inspection_status` — answers "where is the inspection, what is attached, and what do I owe?".
  Each inspection comes back with its status spelled out in plain terms, the carrier's recorded
  discrepancies, and the attached documents. On a bundle, the PARENT risk id expands to every child
  risk's inspection. Most risks have no inspection at all and the tool says so explicitly — that is
  not an error.
- `upload_proof_of_inspection` — files the signed recommendations letter and proof the carrier's
  recommendations were carried out. `risk_ids` is an ARRAY, because one compliance packet routinely
  covers several policies on the same account. Three things to hold onto:
    - **A bundle parent does NOT expand here** (unlike `get_inspection_status`). Pass the child risk
      ids the inspections actually sit on, or the parent is silently skipped.
    - **It is not idempotent server-side.** A second successful call files a second compliance
      submission, a second Novidea sync and a second email to ops. The tool derives file ids from
      the file contents so the documents themselves won't duplicate, and refuses by default when a
      byte-identical document is already attached.
    - **On a timeout the outcome is UNKNOWN, not failed.** Re-run `get_inspection_status` first;
      only re-send if the documents are genuinely absent. Never retry blindly.

### Cancellation & non-renewal (`cancel_or_reinstate_policy`, `mark_policy_non_renew`, `remove_non_renewal`)

Admin only — these require `GLOBAL_ACCESS_PROTECTED_RESOURCE`, and a broker-only session gets
Forbidden. They are the EXECUTE half of ending a policy; `request_policy_cancellation` (below) is
the broker intake half, which only records a request and emails the servicing team. For every
carrier except Vave, these tools are the only in-product way to end a policy at all.

- `cancel_or_reinstate_policy` — stamps the cancellation (or reinstatement) on a BOUND quote and
  logs the activity. `canceled: true` cancels and requires an effective date; `canceled: false`
  reinstates and defaults to today. The reason is free text, but use one of the wordings the app's
  dropdown offers so ops reads the same thing it sees in the app. For Vave policies this also makes
  a live outbound call to the carrier; for everyone else it changes Pathpoint's records only, so the
  carrier must be told separately. A cancellation dated in the future shows as requested but not yet
  in force — that is correct, and worth explaining to the user.
- `mark_policy_non_renew` — records that the policy will not be offered a renewal, with an effective
  date (normally the expiration date) and a reason. It does not end coverage mid-term. This has no
  user interface anywhere in the web app.
- `remove_non_renewal` — undoes the above. Safe to run when nothing was marked, though it logs an
  activity every time. It does NOT undo a cancellation — use `cancel_or_reinstate_policy` with
  `canceled: false` for that.

Identify the policy with `risk_id`; the single bound quote is used by default, and
`quote_identifier` picks one when a risk has several.

### Undoing a mistaken bind (`undo_bind`)

Admin only (`GLOBAL_ACCESS_PROTECTED_RESOURCE`). The correction for a bind that should never have
happened — wrong quote bound, ops error, a bind recorded against the wrong risk. It clears the
quote's bound/issued state so the risk drops back into the bind-requested stage, and it DELETES the
Bound/Issued activity rows, which cannot be restored. That deletion is why this needs an explicit,
confirmed user request — never suggest it as a routine step backwards.

Two boundaries to respect:

- A policy that legitimately existed and now needs to end is a **cancellation**
  (`cancel_or_reinstate_policy`), which preserves the record that coverage was in force. Undo is
  only for binds that were mistakes from the start.
- The bind request survives the undo. If the agent no longer wants to bind at all, follow with
  `cancel_bind_request`.

Same targeting as the other policy tools: `risk_id`, with the single bound quote picked by default.
The tool shows the state before and after so what changed is on the record.

Bound policies only. Load with `enable_toolset` — these six tools are hidden by default.

Broker side:

- `create_endorsement_request` — asks Pathpoint to change a bound policy: additional insureds, named
  insured or DBA, add/remove/move a premises, mailing address, operations, exposure or limits. It
  records the request, emails the servicing team and opens the endorsement in Salesforce; it does
  not change the policy. Takes `risk_ids` (UUIDs — more than one only for sibling risks split off
  the same parent submission), `endorsement_requests` (each an `action` + `sub_action` + free-text
  `answers` whose keys are the question labels the web form shows), `requested_effective_date`,
  optional `additional_information` (max 1000 characters — Salesforce rejects longer) and `files`.
  The tool's own schema lists every valid action → sub-action pair; read it rather than guessing.
- `request_policy_cancellation` — ends a policy instead of changing it. Takes `risk_id`,
  `cancellation_effective_date` and a `reason` (Property sold | Replacement coverage obtained by
  insured | No longer in business | Complaint | Other); `reason: "Other"` needs `reason_details`. A
  signed ACORD 35 is always required, plus proof of sale for "Property sold" or the replacement
  policy for "Replacement coverage obtained by insured". `create_endorsement_request` refuses the
  "Cancel policy" action and points here.
- `list_endorsement_requests` — every endorsement and cancellation request on a risk with each
  requested change's state and the choice ids the ops tools take. State is derived, not stored:
  PENDING until ops resolves it, then ACCEPTED or DECLINED. Optional `status` filter (pending,
  accepted, declined).

Ops side (admin — requires `GLOBAL_ACCESS_PROTECTED_RESOURCE`):

- `confirm_endorsement` — accepts pending choices and records the confirmed endorsement that
  results; it can decline the rest in the same call, and choices left out stay pending. `choices`
  describes what the endorsement actually does, and the server validates each one as an ordered
  tuple — the field keys AND their order must match the action/sub-action pair exactly.
- `decline_endorsement_requests` — declines choices outright with a reason each, creating no
  endorsement. Use it when nothing on the request is going through; the reasons are emailed to the
  agent.
- `get_confirmed_endorsements` — the endorsements actually applied to the policy, with effective
  date and accepted/unbound timestamps.

Three things to know before driving any of this:

- **The four write tools need a BOUND quote with a policy id.** They load it before doing anything
  else, so a risk that was never bound fails with "Quote not found for risk". The two read tools do
  not.
- **Action/sub-action pairing and required forms are enforced client-side only.** The API and the
  database accept any combination and accept a request with no documents at all, so a mismatch would
  be stored and shown to ops as an unrecognised request rather than rejected. That's why the tools
  reject pairs the web form cannot produce (the error names the action the sub-action really belongs
  to) and refuse a request missing its ACORDs. `skip_validation: true` relaxes exactly those two
  checks — it does NOT accept out-of-enum actions, sub-actions or file types, which are always
  rejected.
- **Unmappable products.** `bundle` and `mpl` have no line-of-insurance mapping, so the
  required-forms check downgrades to a warning instead of blocking. On those products the per-choice
  `file_types` can't be derived either — pass it explicitly on each change, or uploaded files attach
  to nothing.

## Administration (admin toolset)

Load with `enable_toolset` — these eight tools are hidden by default.

### Agency networks (`list_agency_networks`, `create_agency_network`, `update_agency_network`)

Partner/network records, not risk work. All three require the `GLOBAL_MANAGE_AGENCY` permission.

- `list_agency_networks` — every network with its id, name, `type` (`STANDARD_NETWORK`,
  `CENTRALIZED_NETWORK`, `AGENCY`), `payer` (`INSURED` or `AGENCY`), commission percentages, Ascend
  account id and flags. Read it first: the id it prints is what the update tool takes.
- `create_agency_network` — needs at least a name and a type; the commission percentages, Ascend
  account id, `appointed` and `hide_commission` are optional.
- `update_agency_network` — identify the network by that id. Only the fields you pass are changed,
  so read the record back to the user before and after.

### Agencies & commissions (`search_agencies`, `set_agency_commission`)

The level below networks: the individual agency, whose commission percentages are what the agency is
actually paid per bind. Both require `GLOBAL_MANAGE_AGENCY`.

- `search_agencies` — find agencies by name and read their commission setup. Names are SQL LIKE
  patterns, so `"Acme%"` matches every agency starting with Acme; a plain name must match exactly.
  Each hit shows the `groupId` (what the setter takes), both commission percentages, network
  membership and flags.
- `set_agency_commission` — write `commission_percent` and/or `mm_commission_percent` on one agency,
  by `groupId`. Values are whole percents (`9.0` = 9%), above 0 and at most 15 — the database
  constrains agency commissions to that range, and the tool refuses out-of-range values before the
  mutation because the server would half-apply them (the unconstrained legacy row is written first).
  Zero is additionally refused because the server's Novidea sync drops falsy values — a 0 would be
  stored in Pathpoint but silently kept at the old rate in Novidea. Only what you pass changes, and
  the change syncs to Novidea. Show the user the current record from `search_agencies` and get a
  clear "yes" before writing — this changes real payouts.

Network membership is deliberately NOT settable here: reassigning an agency to a network makes the
server reset these percentages to the network's defaults, so that stays in the app. Network-level
default commissions live on `update_agency_network` above.

### Your own profile (`get_my_profile`, `update_my_profile`, `set_risk_sharing_scope`)

- `get_my_profile` — the logged-in user's own record: id, email, name, work phone and extension,
  cell phone, NPN, license, email/SMS/terms consent, the default sharing scope applied to new risks,
  and their agency. Read-only and scoped to the session — there is no way to read another user's
  profile.
- `update_my_profile` — self-service edits: `name`, `phone`, `cell_phone`, `npn`,
  `agreed_to_sms_notifications`, `share_risks`. All optional, at least one required. Omitted fields
  are preserved — the tool reads the profile first and re-sends it, because the underlying
  `updateMe` mutation otherwise nulls work phone, extension and SMS consent. Returns a before/after
  diff. Confirm the new values with the user first, and pass `confirm_prod: true` on prod.
    - `license` is admin-only and cannot be set here.
    - Put an extension inline: `phone: "+1 212-555-0142 ext. 12"`. A bare number CLEARS a stored
      extension; `phone: ""` removes the work phone entirely.
    - `name`, `npn` and `cell_phone` cannot be cleared — the server coalesces an empty value back to
      the stored one, so the tool rejects it rather than reporting a change that didn't happen.
    - Any call that keeps SMS consent on re-stamps the consent timestamp to now.
    - If the stored work phone is unparseable, re-sending it fails with "Not a valid US phone
      number". Supply a valid `phone` (or `phone: ""`) alongside whatever else is being changed.
- `set_risk_sharing_scope` — BULK ACTION: rewrites the scope on EVERY risk the user currently owns
  (`access_scope: AGENCY` or `PERSONAL`). No per-risk selection and no undo beyond re-running with
  the other value, so a PERSONAL run un-shares work colleagues may be relying on — get an explicit
  "yes" first, and pass `confirm_prod: true` on prod. It does NOT change the default for risks
  created afterwards (that is `update_my_profile(share_risks=…)`), and for a single risk use
  `share_risk`.

## Loss history (claims toolset)

Load with `enable_toolset` — these four tools are hidden by default.

**Two unrelated things are both called "claim" here.** Getting them confused will produce a very
wrong answer, so establish which the user means before touching anything:

- A **property claim** is a row on a building's loss-history questionnaire — submission data,
  entered while drafting. `add_property_claim`, `delete_property_claims`.
- A **pending claim** is a marker saying a NEW claim has been reported since a quote was issued — a
  post-quote underwriting trigger with side effects far beyond the risk. `list_pending_claims`,
  `flag_pending_claim`.

### Property claims

- `add_property_claim` — adds one **empty** loss-history row to a building. Takes `property_id`
  (from `list_properties`) and `risk_id`. It carries no claim data and does not return the new row's
  id, so it is only half the job: fill it in afterwards with `modify_submission` against the labels
  `Claim Amount`, `Claim Type`, `Claim Date`, `Claim Description` and `Claim Fully Repaired`. The
  building's own gate question ("Has this location had any claims in the last 5 years?") must be
  answered yes for the group to appear. Calling twice adds two empty rows.

    The tool enumerates the risk's buildings first and refuses unless `property_id` is one of them —
    including when that list cannot be read. The server does not make that check itself (it
    authorizes against `risk_id` and then writes to whatever `property_id` it is handed), so this is
    the only thing standing between a mistyped id and a claim landing on someone else's risk.

- `delete_property_claims` — removes loss-history rows by id. **There is no undo through any API** —
  the row is orphaned rather than erased, so its values survive in the database, but nothing exposed
  re-attaches it and `add_property_claim` only ever creates a new empty row. Treat it as permanent
  and expect the data to be re-entered. The batch is all-or-nothing, so one unknown id fails the
  call and deletes nothing, which at least makes retry-after-fix safe. Deleting an already-deleted
  row silently succeeds. Remaining rows renumber positionally, so never echo "Claim 2" back without
  re-reading.

    **Finding the ids is the hard part, and today the MCP cannot.** No query returns claim ids —
    they exist only inside the app's question-group ids. If a user wants a specific claim removed,
    say so plainly and point them at the app rather than guessing at an id.

    The tool does still check ownership before deleting: it enumerates the risk's own loss-history
    rows and refuses the whole batch if any `claim_id` is not among them, including when that list
    cannot be read. That check is the only thing standing in the way — the server authorizes against
    `risk_id` and then deletes whatever `claim_ids` it is handed, so ids from another risk would
    otherwise be orphaned under this risk's authorization.

### Pending claims

- `list_pending_claims` — pending claims on a quote. Defaults to active only; pass
  `include_disabled: true` to see cleared ones too. An unknown or foreign `quote_id` is a
  permissions error, not an empty list.
- `flag_pending_claim` — records that a new claim has been reported against a quote. **Read the
  blast radius to the user before calling.** If the quote's risk has renewals, one call also syncs
  Novidea (Salesforce), clears the broker's selected quote on every renewal, hides every **VAVE**
  renewal quote from the broker, and writes a carrier-worded `REFERRED` activity saying underwriting
  review is required. Quotes already bound, issued, or with a live bind request are spared.
  **Clearing any of this is only possible in the app**, so confirm before, not after. The API itself
  does not de-duplicate, but the tool does: it reads the live markers first and refuses if the quote
  is already flagged, so a repeated call is safe and its refusal is not an error to route around.

## Hazard data (hazard toolset)

Load with `enable_toolset` — this one tool is hidden by default.

- `order_wildfire_scores` — orders CoreLogic wildfire scores for a risk's western-state locations
  and files the report into Novidea. **Internal ops/QA work, not part of the broker flow** — the web
  app hides its only button behind a QA permission flag, so do not offer it to a broker unprompted.

    **It only queues.** Success means the job was accepted onto a queue and nothing more: no scores
    fetched, no report filed, nothing in Novidea changed yet. There is no query anywhere for the
    status of a wildfire order, so completion can only be confirmed in Novidea or by ops — never
    from here. Never call it a second time to check whether it worked: every call is a fresh
    **billable** vendor order (two live CoreLogic requests per location, no dedupe). And two silent
    no-ops are normal rather than bugs — the worker orders nothing if no carrier on the risk
    requires wildfire scores, or if the risk has no western-state locations.

## Not covered by these tools (use the app)

Check `list_toolsets` before telling a user something is unavailable — most of what looks missing is
merely a hidden group. What genuinely is not here:

- **E-signing** — the interactive signing ceremony, and the signing URL and manual-sign fallback
  documents.
- **Mid-term adjustments** — the MTA wizard, which previews a premium delta and creates a separate
  risk. Distinct from `create_endorsement_request`, which files an ops-mediated request and does not
  price the change.
- **Premium financing** — financing estimates and payment programs.
- **State surplus-lines subjectivity forms** — the per-state forms that can block a bind. Ordinary
  subjectivities ARE covered by `list_subjectivities` and `answer_subjectivity`.
- **Changing policy dates on a bound quote.**
- **Extracted document field values** — `get_extraction_status` reports how extraction is going, but
  the extracted values themselves, and cancelling a running extraction, are app-only.
- **Creating broker users** — the `admin` toolset covers agency-network records and the logged-in
  user's own profile, not adding people.
- **Importing a risk from JSON.**

Endorsement requests, policy cancellation, non-renewal, inspection compliance, loss history and
wildfire orders ARE covered — in the `endorsements`, `policy`, `claims` and `hazard` toolsets.

## Display Formatting

When showing risk details to the user, format as:

```
Acme Cyber Corp
Status: QUOTED | Effective: 2026-05-01 — 2027-05-01
Product: Cyber (cyber)

Submissions:
  1. At-Bay — DECLINED (no quotes)
  2. Kinsale — QUOTED
     Quote KIN-001: $4,200 (admitted)
     Limits: $1M aggregate / $1M occurrence / $10K retention
```

Risk IDs and EIDs are internal — keep them as the parameters you pass back to the next tool call,
not as user-facing output.

When confirming actions, show before/after:

```
Updating quote KIN-001 (Kinsale):
  Premium:    $4,200 → $4,800
  Agency Fee: (none) → $500

Proceed?
```
