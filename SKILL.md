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

## Domain Knowledge

The MCP tools handle all the mechanics. The skill's job is knowing what to ask.

### Finding risks (`search_risk` vs `list_risks`)

- `search_risk` — use when the user names a specific company or knows the UUID. Accepts a single
  query string; returns matches on named insured.
- `list_risks` — use for "show me my recent submissions" or "what's in the queue". Optionally filter
  by status (`DRAFT`, `SUBMITTED`, `QUOTED`, `BOUND`, `ISSUED`, `DECLINED`, `REFERRED`). Defaults to
  the 20 most recent; max 50.

### What needs attention (`get_action_items`)

Use for "what's on my plate?", "anything I need to do?", or as a morning round-up. Defaults to the
user's own risks; pass `scope: AGENCY` when they ask about their whole agency. Follow up on a
specific item with `get_risk` / `get_risk_activity`.

### Activity history (`get_risk_activity`)

Use for "what's the latest on this risk?", "any notes from the team?", or before summarizing a
risk's state. Returns notes, submissions, quote letters, bind requests, and declines, most recent
first. Attached files show by name only — use `list_risk_files` when the user wants a download link.

### Submitting a risk (`submit_risk`)

Submits a drafted risk to its markets for quoting — the same action as the Submit button in the app.
Before calling:

1. Confirm required fields are filled (`list_fields`); fix gaps with `modify_submission`.
2. Show the user a summary of the risk (`get_risk`) and confirm they want to submit.

Validation failures come back listing the missing fields — relay them in plain English and offer to
fill them. After a successful submit, the tool returns the refreshed risk summary; report which
markets it went to and any instant quotes or declines.

### Requesting to bind (`request_bind`)

The conversion action — tells the Pathpoint team the agent wants to bind a quote. Identify the quote
the same way as `update_quote` (number or EID, plus `risk_id`). The tool selects the quote on the
risk automatically if it isn't already selected.

Always confirm before calling — show carrier, quote number, premium, and effective dates, and get an
explicit "yes". After requesting, check `list_subjectivities` for outstanding requirements and tell
the user what's still needed to complete the bind.

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

### Selecting a quote & TRIA (`select_quote`, `set_tria`)

`select_quote` marks the quote the agent intends to bind and generates its bind checklist — use it
when the user picks a quote but isn't ready to request bind (request_bind selects automatically).
`set_tria` toggles terrorism coverage on a quote; premium and fees change, so show the updated
`get_quote` cost afterwards.

### Renewal review (`get_renewal_changes`)

After `renew_risk` (or on any renewal), shows field-by-field diffs against the expiring term with
who changed what and when. Useful for "what's different on the renewal?" before submitting it.

### Not covered by these tools (use the app)

E-signing (interactive ceremony), endorsement and mid-term-adjustment requests (structured wizards),
and policy cancellation/non-renewal (Pathpoint ops only). When users ask for these, point them to
the app rather than improvising.

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
   multiple tenancies, one canonical string per line) — free text fails silently at rating.
7. **Loop** steps 5–6 until `get_submission_questions` reports all required questions answered and
   no validation errors. Mid-flow corrections ("actually the effective date is June 1") are just
   another `modify_submission` call.
8. **Submit** via the existing `submit_risk` flow: summary, explicit confirmation, then report which
   markets it went to and any instant quotes or declines.

#### GL / class-of-business products (cglV2 and friends)

GL-family submissions classify the business with 5-digit class codes instead of (or alongside)
tenancies:

- **Class of business page.** The vertical picker (type hint mentions class codes, e.g. "What type
  of contractor is your applicant?") stores comma-separated 5-digit codes. Ask what the business
  actually does, use `search_class_codes` to find candidates, offer the top matches in plain
  English, then write the code(s) comma-separated (e.g. `"91560,91580"`). Free text fails
  classification silently at rating — never invent codes.
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

#### Excess standalone products (`contractorsExcessStandalone`, `lroExcessStandalone`)

Excess submissions add an underlying-policy block: carrier (a huge validated select — search it by
what the user says, offer close matches), A.M. Best confirmation, underlying premium, dates, and
limits. Two of the limit questions ("General Aggregate Limit", "Products-Completed Operations
Limit") list NO options — they store integers, so write plain numbers (`2000000`), never
`"$2,000,000"` text (it passes validation but fails server-side). Their siblings that do list
options ("Per Occurrence Limit") take the option text as usual.

#### Value types and look-alike checkbox groups

- Write numbers as numbers: year, count, and money questions reject numeric strings server-side, and
  a `modify_submission` batch is all-or-nothing — one bad value rejects every change in the call.
- When several checkbox groups share the same truncated header (e.g. three different "Select all of
  the following that apply to any location: › None of the above" rows), a colliding write errors and
  lists the full disambiguated paths — copy one back verbatim, including any `:_suffix` in the group
  text. If a bare write silently satisfies only one of the look-alike groups, the progress counts
  reveal the ones still missing.

### Renewals (`renew_risk`)

Use when the user wants to renew an expiring policy/term. The tool creates a renewal draft linked to
the original and carries data forward — it refuses to duplicate an existing renewal and reports it
instead. After creating, review dates and exposures with the user (`list_fields`), apply updates,
then `submit_risk`.

### Files (`upload_risk_file`, `delete_risk_file`)

`upload_risk_file` attaches a local file (loss runs, supplementals, ACORDs, signed docs) to a risk —
ask for the file's path, confirm name and target risk, then upload and verify with
`list_risk_files`. For submission documents (ACORDs, supplementals), pass `extract: true` so
extracted values prefill the application — track progress with `get_extraction_status`.
`delete_risk_file` is a soft remove by file EID; confirm before deleting, same as quotes.

### Bind readiness (`check_bind_readiness`)

Run before `request_bind` or whenever the user asks "can I bind this yet?" — it reports validation
blockers and incomplete subjectivities without changing anything. Walk the user through fixing each
blocker (`answer_subjectivity`, app uploads), then re-check.

### Agency directory (`list_agency_users`)

Lists names and emails at the user's agency. Use it to resolve "assign this to Sarah" into an exact
email for `set_risk_owner`, or to pick a licensed agent.

### Loss runs (`request_loss_runs`)

For bound/issued risks when the user asks for loss runs. The documents arrive asynchronously — check
`list_risk_files` later rather than promising instant results.

### Quote documents (`get_quote_documents`)

Use when the user wants the quote letter, proposal, invoice, binder, or policy paperwork. Returns
presigned download URLs — share the link, not the raw URL string dump. If nothing is attached yet,
say so; quote letters can take a few minutes to generate after quoting.

### Canceling a bind request (`cancel_bind_request`)

The undo for `request_bind` — use when the client backs out or the wrong quote was requested. Always
collect a reason (it goes to the Pathpoint team) and confirm before calling.

### Resubmitting (`resubmit_risk`)

Use after quotes expire, markets decline, or the submission changed — "get me fresh quotes" or
"resubmit to Vave". Targets specific carriers by name or all submittable markets when omitted.
Carrier names are validated against the risk's submittable markets and the error lists the options,
so on a mismatch just relay the choices.

### Sharing & ownership (`share_risk`, `set_risk_owner`)

- `share_risk` — "share with my team" → scope AGENCY; "make this private" → PERSONAL.
- `set_risk_owner` — hand a submission to a teammate by email. Confirm the email before calling; the
  user must already exist in Pathpoint.

### Quoting (`quote_risk`)

The tool now routes limits into the correct typed input automatically based on the risk's product.
You usually don't need to pass `product` — it's inferred from the risk. Pass it only if the user
explicitly overrides (rare).

Determine the product type from the risk, then ask for the right limits:

| Product                      | Limits to ask                                                                                        |
| ---------------------------- | ---------------------------------------------------------------------------------------------------- |
| Cyber                        | `aggregate_limit`, `per_occurrence_limit`, `retention`                                               |
| GL (CGL)                     | `aggregate_limit`, `per_occurrence_limit`, `products_completed_ops`                                  |
| Excess                       | `aggregate_limit`, `per_occurrence_limit`, `products_completed_ops`                                  |
| Property / Monoline Property | `aggregate_limit` (use the flat limit; other property fields live in the application, not the quote) |

Always ask:

- **Premium** (required)
- **Carrier** — can be picked from existing submissions or named freely
- **Effective/expiration dates** — default from the risk, confirm with user
- **Quote number** — optional
- **Fees** — agency, company, stamping, inspection (ask once, skip if none)
- **TRIA** — optional
- **Admitted or non-admitted** — default non-admitted (omit `admitted` to keep the default). Pass
  `admitted: true` for admitted.
- **Comment** — optional

### Viewing quote details (`get_quote`)

When the user asks about a specific quote, use `get_quote` to show the full picture — cost breakdown
(premium, fees, taxes), limits, subjectivities, and status flags. Identify the quote by:

- **EID** — pass directly as `quote_identifier`
- **Quote number** — pass as `quote_identifier` along with `risk_id`

If the user picks a quote from the `get_risk` summary, use the EID shown there.

### Updating quotes (`update_quote`)

Show the existing quotes from `get_risk` as a numbered list with carrier, quote number, premium, and
status. Let the user pick one. Use `get_quote` to show full current details, then ask what to
change. Accept free-form input — "change premium to $4,200 and add a $500 agency fee" — and map to
the tool parameters.

Limit parameters are routed by product the same way as `quote_risk`. To flip an admitted quote to
non-admitted, pass `admitted: false` explicitly (omitting it leaves the current value alone).

Show a before/after summary before executing.

### Deleting quotes (`delete_quote`)

This is a soft delete — the quote is marked deleted and hidden from normal queries, but the action
is not typically reversible from the UI. Always confirm with the user before calling the tool:

```
Delete quote KIN-001 from Acme Cyber Corp (Kinsale, $4,200)?
This cannot be undone from the app.
```

Only call `delete_quote` after an explicit "yes". Never default to delete when the user says
"remove" or "cancel" — ask if they mean delete vs. unbind vs. decline.

### Modifying submissions (`modify_submission`)

In the conversational submission flow, `get_submission_questions` is the preferred discovery step:
it returns the live question set with current labels, so you can modify directly without a separate
lookup. Call `list_fields` instead for a quick label/value lookup outside that flow. Either way,
fields vary by product type, and a draft with no product assigned may have no fields at all.

- If `get_risk` shows "Product: (none assigned)", the risk needs a product type before fields can be
  modified.
- If `list_fields` returns no fields, tell the user and suggest checking the product assignment.
- Use `list_fields` with a specific `view` to narrow results (e.g. `ORGANIZATION_INFORMATION` for
  address/revenue, `COVERAGE_OPTIONS` for dates/limits).

The `modify_submission` tool accepts human-readable field labels (e.g. "Organization Name", "Annual
Revenue") and resolves them internally. Use the exact labels from `list_fields` to avoid mismatches.

If the user pastes unstructured data (broker email, correction form), extract field changes, verify
the labels against `list_fields`, and confirm before executing.

After a write, the tool reports any questions that appeared or disappeared as a result (the form is
conditional) plus how many required answers remain — relay new questions to the user instead of
re-listing everything.

### Cloning submissions (`clone_submission`)

Show a summary of the source risk. Ask:

1. "Do you want to change anything on the new submission?" — collect changes as field/value pairs
2. "Submit for quoting right away, or leave as draft?"

The tool handles creating the risk, copying values, applying changes, and optionally submitting —
all in one call. If the source risk has no product assigned, clone will fail with a clear error;
have the user fix that on the source before retrying.

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
