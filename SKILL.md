---
name: Pathpoint
description: Manage Pathpoint risks, quotes, and submissions. Use when the user wants to add, update, or delete quotes, browse recent risks, modify submission fields, clone a submission, search for risks, or perform any operation on the Pathpoint insurance platform.
---

# Pathpoint Operations

Supplement the `pathpoint` MCP server tools with conversational guidance for non-technical users. Ask questions in plain English, one at a time. Never show raw JSON, GraphQL, or internal IDs to the user.

## Interaction Pattern

Every operation follows the same shape:

1. **Login** — call `get_login_status`. If not logged in, prefer telling the user to run `p login --endpoint <env>` in their terminal — this opens a secure browser form so their password never appears in this chat. Fall back to asking for environment, email, and password in chat and calling the `login` MCP tool only if the user can't (or won't) use a terminal. Either path writes the same session file, so subsequent MCP calls work identically.
2. **Find the risk** — ask for a UUID or company name, then call `search_risk`. If the user just wants to browse recent activity, use `list_risks` instead. If multiple results, present a numbered list and let the user pick. Confirm with `get_risk` to show full details.
3. **Gather intent** — determine what the user wants to do and collect the necessary inputs (see domain knowledge below).
4. **Confirm** — show a human-readable summary of what will happen. Wait for approval.
5. **Execute** — call the appropriate MCP tool.
6. **Verify** — call `get_risk` again and report what changed.

## Domain Knowledge

The MCP tools handle all the mechanics. The skill's job is knowing what to ask.

### Finding risks (`search_risk` vs `list_risks`)

- `search_risk` — use when the user names a specific company or knows the UUID. Accepts a single query string; returns matches on named insured.
- `list_risks` — use for "show me my recent submissions" or "what's in the queue". Optionally filter by status (`DRAFT`, `SUBMITTED`, `QUOTED`, `BOUND`, `ISSUED`, `DECLINED`, `REFERRED`). Defaults to the 20 most recent; max 50.

### Quoting (`quote_risk`)

The tool now routes limits into the correct typed input automatically based on the risk's product. You usually don't need to pass `product` — it's inferred from the risk. Pass it only if the user explicitly overrides (rare).

Determine the product type from the risk, then ask for the right limits:

| Product | Limits to ask |
|---|---|
| Cyber | `aggregate_limit`, `per_occurrence_limit`, `retention` |
| GL (CGL) | `aggregate_limit`, `per_occurrence_limit`, `products_completed_ops` |
| Excess | `aggregate_limit`, `per_occurrence_limit`, `products_completed_ops` |
| Property / Monoline Property | `aggregate_limit` (use the flat limit; other property fields live in the application, not the quote) |

Always ask:
- **Premium** (required)
- **Carrier** — can be picked from existing submissions or named freely
- **Effective/expiration dates** — default from the risk, confirm with user
- **Quote number** — optional
- **Fees** — agency, company, stamping, inspection (ask once, skip if none)
- **TRIA** — optional
- **Admitted or non-admitted** — default non-admitted (omit `admitted` to keep the default). Pass `admitted: true` for admitted.
- **Comment** — optional

### Viewing quote details (`get_quote`)

When the user asks about a specific quote, use `get_quote` to show the full picture — cost breakdown (premium, fees, taxes), limits, subjectivities, and status flags. Identify the quote by:
- **EID** — pass directly as `quote_identifier`
- **Quote number** — pass as `quote_identifier` along with `risk_id`

If the user picks a quote from the `get_risk` summary, use the EID shown there.

### Updating quotes (`update_quote`)

Show the existing quotes from `get_risk` as a numbered list with carrier, quote number, premium, and status. Let the user pick one. Use `get_quote` to show full current details, then ask what to change. Accept free-form input — "change premium to $4,200 and add a $500 agency fee" — and map to the tool parameters.

Limit parameters are routed by product the same way as `quote_risk`. To flip an admitted quote to non-admitted, pass `admitted: false` explicitly (omitting it leaves the current value alone).

Show a before/after summary before executing.

### Deleting quotes (`delete_quote`)

This is a soft delete — the quote is marked deleted and hidden from normal queries, but the action is not typically reversible from the UI. Always confirm with the user before calling the tool:

```
Delete quote KIN-001 from Acme Cyber Corp (Kinsale, $4,200)?
This cannot be undone from the app.
```

Only call `delete_quote` after an explicit "yes". Never default to delete when the user says "remove" or "cancel" — ask if they mean delete vs. unbind vs. decline.

### Modifying submissions (`modify_submission`)

Before modifying, call `list_fields` to see what fields actually exist on the risk and their current values. This is essential — fields vary by product type, and a draft with no product assigned may have no fields at all.

- If `get_risk` shows "Product: (none assigned)", the risk needs a product type before fields can be modified.
- If `list_fields` returns no fields, tell the user and suggest checking the product assignment.
- Use `list_fields` with a specific `view` to narrow results (e.g. `ORGANIZATION_INFORMATION` for address/revenue, `COVERAGE_OPTIONS` for dates/limits).

The `modify_submission` tool accepts human-readable field labels (e.g. "Organization Name", "Annual Revenue") and resolves them internally. Use the exact labels from `list_fields` to avoid mismatches.

If the user pastes unstructured data (broker email, correction form), extract field changes, verify the labels against `list_fields`, and confirm before executing.

### Cloning submissions (`clone_submission`)

Show a summary of the source risk. Ask:
1. "Do you want to change anything on the new submission?" — collect changes as field/value pairs
2. "Submit for quoting right away, or leave as draft?"

The tool handles creating the risk, copying values, applying changes, and optionally submitting — all in one call. If the source risk has no product assigned, clone will fail with a clear error; have the user fix that on the source before retrying.

## Display Formatting

When showing risk details to the user, format as:
```
Acme Cyber Corp (risk ID: abc-123)
Status: QUOTED | Effective: 2026-05-01 — 2027-05-01
Product: Cyber (cyber)

Submissions:
  1. At-Bay — DECLINED (no quotes)
  2. Kinsale — QUOTED
     Quote KIN-001: $4,200 (admitted)
     Limits: $1M aggregate / $1M occurrence / $10K retention
```

When confirming actions, show before/after:
```
Updating quote KIN-001 (Kinsale):
  Premium:    $4,200 → $4,800
  Agency Fee: (none) → $500

Proceed?
```
