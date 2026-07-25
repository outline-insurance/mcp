# Changelog

All notable changes to the `p` CLI are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
