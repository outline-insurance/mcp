# Changelog

All notable changes to the `p` CLI are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.12] - 2026-07-26

### Added

- `attach_quote_file` — upload a local file and attach it to a quote as a typed quote document.
  Attaching a `QUOTE_LETTER` clears the "missing quote letter" blocker that stops `request_bind` on
  manual quotes.
- `create_bind_request_task` — puts a quote into the Pathpoint ops bind-request queue, which
  `request_bind` alone does not do. Idempotent; `cancel_bind_request` withdraws it.
- `get_my_profile`, `update_my_profile` and `set_risk_sharing_scope` — read and update your own
  profile (name, phone, cell, NPN, SMS consent, default risk sharing) and bulk re-scope owned risks.
- Endorsement lifecycle tools — `create_endorsement_request`, `list_endorsement_requests`,
  `get_confirmed_endorsements`, `confirm_endorsement`, `decline_endorsement_requests` and
  `request_policy_cancellation` — with client-side validation of required ACORD forms.
- The Boost carrier is now resolvable by market name/UUID, and new tests keep the market tables and
  every hand-written GraphQL document in sync with the API schema.
- `list_toolsets` and `enable_toolset` — see which tool groups exist, which are loaded, and load one
  mid-session without restarting the server.
- `get_appetite` — ask the PALMS rules engine which carriers want a risk and, when they don't, why
  not: four buckets per coverage (MAY_PROCEED, WILL_REFER, MIDDLE_MARKET_ELIGIBLE, WILL_DECLINE)
  with per-carrier reasons in plain English. The only way to see a decline reason before submitting.
- `create_excess_from_quote` — spawn a standalone excess (umbrella) submission from a quote on an
  underlying GL risk, with the underlying-policy block (carrier, premium, limits, dates) seeded from
  that quote.
- Multi-location submissions: `list_properties`, `add_property`, `duplicate_property` and
  `delete_property` lift the one-building ceiling `create_risk` used to impose. Per-building answers
  are addressed by ordinal path prefixes (`Property 2 › Building Limit`), which `list_properties`
  prints for each building.
- Post-bind policy servicing (admin): `cancel_or_reinstate_policy`, `mark_policy_non_renew` and
  `remove_non_renewal`. For every carrier except Vave these are the only in-product way to end a
  policy; `mark_policy_non_renew` has no user interface anywhere in the web app.
- Inspection stage: `get_inspection_status` (where the inspection stands, its discrepancies and
  documents, with bundle parents expanding to their children) and `upload_proof_of_inspection` (file
  the signed recommendations letter and proof of compliance against one or more policies).
- Insured contact: `get_insured_contact` and `set_insured_contact` — the real record behind the
  e-sign recipient and the Inspection Contact / Insured Pay / Audit Contact subjectivity answers,
  which writing JSON into a CONTACT_INFO subjectivity never populated.

### Changed

- **BREAKING (default behaviour)** — `p mcp-serve` now loads only the `core` toolset: finding and
  reading risks, building and submitting an application, quoting, subjectivities and binding. The
  `endorsements`, `policy`, `properties` and `admin` groups are hidden from `tools/list` until
  loaded with `--toolsets <names>`, `$P_MCP_TOOLSETS`, or `enable_toolset` mid-session. The default
  payload drops from 86,791 bytes / 69 tools to 49,861 bytes / 49 tools (43% smaller). Hiding is a
  context-budget measure, not a permission boundary — a hidden tool is still callable by name, and
  everything security-relevant is enforced server-side. Sessions that relied on endorsement,
  policy-servicing, property or admin tools being present must pass `--toolsets`.
- Every mutating tool now refuses to run against a prod session without `confirm_prod=true`; 11
  tools that were missing the guard gained it, and tool annotations no longer advertise a mutating
  tool as read-only or non-destructive.
- `list_risk_files` and `get_quote_documents` no longer return presigned download URLs by default —
  pass `include_urls=true` when the user actually wants to open a document. Responses are ~93%
  smaller.
- Request timeouts are sized per operation instead of one flat budget: 300s for bind, issue and
  document generation, 120s for quoting and submission, 30s otherwise (`--timeout` still overrides
  everything). A timeout now says explicitly that THE OPERATION MAY HAVE COMPLETED SERVER-SIDE, and
  for a bind it says to re-check the quote's state rather than retry — a blind retry is how a policy
  gets bound twice.
- Common server errors now lead with a plain-English explanation of what went wrong before the raw
  GraphQL message.
- `check_bind_readiness` and `request_bind` now point at `attach_quote_file` when the blocker is a
  missing quote letter.
- `check_bind_readiness` now names the tool that clears each incomplete subjectivity
  (`upload_subjectivity_file` for FILES, `answer_subjectivity` for the rest) and no longer lists
  every item twice.
- `list_fields` and `get_submission_questions` prepend a `WARNING — THIS RESULT IS INCOMPLETE`
  banner when the server rejected a submission view this build queries, naming the views that were
  not read — so a partial listing can no longer be mistaken for "that field does not exist".
- `quote_risk` and `update_quote` now quote package products, routing their limits into the
  general-liability input the server resolves them to.
- The bundled skill file is reordered around the everyday login → find → read → modify → submit →
  quote → bind loop, with the specialist and admin material moved below it, and it now documents
  every registered tool. `decline_submission`, `list_agency_networks`, `create_agency_network`,
  `update_agency_network` and `request_bind`'s `licensed_agent_email` parameter had all shipped
  undocumented, which in practice meant unreachable; a test now fails when a registered tool is
  missing from the skill file, or the skill file advertises one that no longer exists.

### Fixed

- `search_risk` actually filters now. It was sending a `searchString` argument the API ignores, so
  every search returned the same ten most recent risks regardless of the query. It also rejects a
  blank query (which would return unfiltered recents that look like matches) and warns when the
  results do not contain the search term.
- `quote_risk` and `update_quote` reject `bundle` and `mpl` risks with an explanation instead of
  building a request the server cannot answer: a bundle has no single line of insurance, and mpl has
  no line-of-insurance mapping at all.
- When a quote number matches more than one quote — quote numbers are not unique — the quote tools
  now list the candidates and ask for an EID or UUID instead of silently acting on whichever one
  came back first.

## [0.0.11] - 2026-07-25

### Added

- Conversational submission creation: new MCP tool `get_submission_questions` (live required-field
  progress, missing questions with types/options/prefills, validation errors), `modify_submission`
  now validates select options, reports all unmatched labels at once, and returns a post-write diff
  of newly appeared/removed questions, `upload_risk_file` gains `extract: true` to run document
  extraction, and new `get_extraction_status` tool tracks it.
- Tenancy-type support: new MCP tool `search_tenancy_types` searches the catalog and returns exact
  copyable `"<code>: <description>"` strings, and `modify_submission` validates TENANTS fields
  against the catalog (dash/case/whitespace-insensitive, one canonical string per line for multiple
  tenancies), substituting the exact form — so free-text tenancies no longer fail silently at
  rating.
- Class-of-business support for GL-family products: new MCP tool `search_class_codes`
  (embeddings-backed, filterable by product), 5-digit CSV validation and discovery hints on
  class-code pickers, and validation + re-marshaling of the per-location exposure JSON ("Class of
  business and exposure values") — malformed JSON in that field used to break every read of the
  risk.
- `create_risk` gains `tenancy_types` and `class_codes` preselects, mirroring the web coverage
  finder's create-time `preselectedAttributeValues`. Property raters hard-require an occupancy and
  some products never serve the corresponding question in the flow (`packageRestaurants` for
  tenancy, `cglManufacturing` for class codes), making creation the only conversational chance to
  set them — a risk created without them is declined by every market with no appetite reason given.
  Inputs are validated against the live catalogs, and the tool diffs the server's `preselected` echo
  against the request, warning per silently dropped value.
- Question-state coverage grew from 11 to 26 views (CLASS_OF_BUSINESS, SUBCONTRACTORS,
  MIDDLE_MARKETS_INFORMATION, and others were previously invisible), with a core-views retry when an
  older server rejects an unknown view enum.

### Changed

- US state answers are normalized to 2-letter codes ("Georgia" → GA) on state selects — full state
  names used to pass validation and then fail silently at quote persistence.
- Checkbox-group members and repeated fields are addressable by qualified `Group › Label` paths
  derived from the group question text (keeping the `:_suffix` disambiguator when sibling groups
  share a header). Ambiguous inputs error with the full copyable paths instead of silently writing
  the first match, and a batch that reaches the same stored field through two labels is rejected
  with a "write it once" error.

### Fixed

- A bare label that exactly matches a question no longer loses to a longer label in an earlier view
  that merely starts with it — "Expiration Date" copied from the question list used to silently
  write "Expiration Date of Underlying Liability Policy" on excess products.
- Option lists in type hints and rejection errors quote every option text when any of them contains
  a comma, so a single option like "Association, Labor Union, Religious Organization" (or "$2,500")
  no longer reads as several separate options.
- The segmented vertical picker and "What type of work is subcontracted?" share one stored
  attribute; writes now merge per catalog subset instead of overwriting each other (a naive write
  used to flip the vertical and discard eligibility answers).

## [0.0.10] - 2026-07-06

### Added

- `p mutation createAgencyNetwork` and `p mutation updateAgencyNetwork` — create and update agency
  networks via the new GraphQL API (#15638). Both take `--input '<json>'`; `type` is one of
  `STANDARD_NETWORK`, `CENTRALIZED_NETWORK`, `AGENCY` and `payer` is `INSURED` or `AGENCY`.
- MCP tools `list_agency_networks`, `create_agency_network`, and `update_agency_network` (admin —
  `GLOBAL_MANAGE_AGENCY`). The create/update tools refuse to write on a prod session unless
  `confirm_prod=true`.

### Changed

- `p query getAgencyNetworks` now returns the full record (commission percentages, Ascend account
  id, `appointed`, `payer`, `hideCommission`, `type`) instead of just id and name.

### Fixed

- The CLI code generator now includes enum-typed fields in default selection sets (previously
  dropped) and keeps enum-typed arguments as plain string flags.

## [0.0.9] - 2026-06-24

### Added

- WKFC Underwriting Managers is now a recognized carrier in the MCP server. Quote and resubmit tools
  resolve `WKFC` (or "WKFC Underwriting Managers") to its market and UUID, matching the carrier
  added to the product in #15570.
- A public landing page for the MCP server (served via GitHub Pages from the release repo), with
  copy aligned to the Pathpoint brand voice and platform icons for macOS, Linux, and Windows.

## [0.0.8] - 2026-06-18

### Changed

- `p login` now treats an explicit `--endpoint` that differs from your active session as an
  environment switch: it logs out of the current session and authenticates against the newly
  requested environment, instead of just reporting that you're still logged in to the old one. A
  bare `p login` with no `--endpoint` is unchanged — it still reports the status of the active
  session rather than switching to the default environment.

## Earlier releases

Versions v0.0.1–v0.0.7 predate this changelog; see the
[GitHub releases](https://github.com/outline-insurance/mcp/releases) for their history.
