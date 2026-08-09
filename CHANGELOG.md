# Changelog

All notable changes to the `p` CLI are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.25] - 2026-08-08

Three layers of defense against classless submissions (ENG-916). An agent-driven integration created
cglV2 submissions preselecting class codes from a different product's picker; the server silently
dropped every code, stored an empty class of business that its own completeness check reads as
answered, and the risks were submitted with no class of business. Each one reaches markets with no
appetite match and lands in the UW referral queue.

### Added

- `create_risk` now validates `class_codes` against the requested coverage's class-of-business
  picker option set before creating anything, from a bundled port of the same catalog the server's
  sanitize step reads (drift-tested against the monorepo's class-code JSON on every test run). Codes
  from a different product's picker fail the call with "(no risk created)", naming each offending
  code's description, its actual group, and the coverages it IS valid for — steering the agent to
  reconsider the coverage id (the incident's failure mode: right business, wrong product) or re-run
  `search_class_codes`. Codes unknown to the catalog are refused too. Coverages outside the picker
  mapping keep the structural check only — `bundle` (its option set depends on the child coverages)
  and unmapped coverages like monolinePropertyV2 or cyber, where the server fails open and stores
  the codes as given; the pre-flight mirrors that exactly rather than refusing preselects that work
  today. Motivation: the server's sanitize step silently drops wrong-product codes and stores an
  empty class of business — the create succeeds, nothing warns, and the classless risk looks
  submittable.
- A classless-submit guard in `submit_risk`, `clone_submission` (when submitting), and
  `resubmit_risk`. Before the mutation fires, the tool reads the risk's class-of-business question
  state; a REQUIRED class-of-business picker holding an empty or blank value refuses the submit with
  remediation (`search_class_codes` → `modify_submission` → retry). The check inspects the value
  itself, because the server's completeness flag treats the empty string as answered — the exact
  trap that let these submissions through. `clone_submission`'s refusal comes after the clone is
  created, as a success-shaped "NOT SUBMITTED" banner naming the new risk id, so the clone is never
  stranded. When the question state cannot be read at all, all three refuse fail-closed with a
  distinct "could not be verified" message. Optional pickers (cglManufacturing) and coverages
  without a class-of-business question are unaffected. Motivation: submitRisk validates none of this
  server-side, so the guard is the only gate between a classless draft and every market.

### Changed

- A create whose requested class codes were ALL dropped by the server now returns an error-level
  result instead of a warning inside a success. After the pre-flight, a total drop is the residue
  the local catalog cannot predict (drift, a server-side change, bundle) — and a WARNING beside
  "Created draft risk" gets skimmed. The error still names the created risk id, states that the risk
  WAS created but its class of business is UNSET and it must not be submitted until fixed, and says
  that any field changes requested in the same call were NOT applied. Partial drops remain warnings
  in a success result, as before.

### Fixed

- The create response's applied-preselects echo no longer renders an attribute echoed with no values
  — a bare "classCodes:" line read as if it were a value — and a drop that left nothing applied now
  says "No preselects were applied" instead of implying the rest landed. The `class_codes`
  parameter's example also moved from 16900 (a restaurants code) to 91560 (a cglV2 contractor code):
  the old example modeled exactly the wrong-product pairing the new validation refuses.

## [0.0.24] - 2026-08-08

Closes out the ENG-914 contract queries. Nothing here is a new tool, deliberately: the core
`tools/list` budget is effectively full, so each answer rides an existing tool's output or SKILL.md
instead of spending a slot. Two of the ticket's five queries were closed without shipping anything —
one superseded, one whose source document is dead — with the reasoning recorded on ENG-914.

### Added

- `get_quote` now lists carrier coverage adjustments ("modifications") on the quotes that carry them
  — the package segments, monoline property/wind, and Churches-GL — naming the buildings each
  adjustment affects, and stating explicitly when none were recorded so silence cannot be misread as
  unamended coverage. Other coverages never carry modifications, so the tool does not fetch them
  there. Motivation: a modification is the carrier amending what the quote actually covers, per
  building, and it was visible only in the app's quote view — an agent relaying a quote
  conversationally could present terms the carrier had already adjusted.
- `get_risk` on a mid-term adjustment (MTA) now names the root policy risk the adjustment applies
  to. An MTA is a separate risk hanging off a bound policy, and the summary previously presented it
  as free-standing — nothing told the agent that the governing policy, its documents, and its dates
  live on another risk entirely.
- `get_renewal_changes` now leads with the expiring term's carrier of record, or "not recorded" when
  the prior term never bound. Who held the risk last term is the first thing a broker asks alongside
  a renewal diff, and the diff previously never said — the agent had to fish it out of the expiring
  risk's submission list.
- SKILL.md gained a "Coverage ids" table: all 22 released coverage ids with display name and
  admitted/non-admitted status, sourced from `shared/constants/product.ts` and stamped "as of
  0.0.24" so drift is traceable. `create_risk`'s tool description now points at the table. This is
  the deliberate replacement for the getProducts tool floated at intake — a static list that changes
  a few times a year does not earn a permanent tool slot in a full tools/list.

## [0.0.23] - 2026-08-07

### Added

- A once-a-day update nudge. When a newer release is known, most commands print a single line to
  stderr at startup — "p 0.0.24 is available (running 0.0.23) — run `p update` to install" — read
  from a local cache at `~/.config/p/update-check.json`, never from the network: when the cache is
  more than 24 hours old, a fire-and-forget background refresh updates it for a later run, so no
  invocation gains latency or a network dependency, and offline or air-gapped machines simply stay
  silent. `update`, `doctor`, `version`, `completion`, and `mcp-serve` are excluded — the first
  three already answer the version question themselves, completion output is consumed by shells, and
  mcp-serve gets the MCP-native note below instead. Set `P_NO_UPDATE_CHECK` to any non-empty value
  to turn it off; dev/local builds never nudge (comparison fails closed — see Fixed). Motivation:
  `p update` only helps users who know a release happened; external beta users install once, drift
  versions behind, and then hit bugs that were fixed weeks ago.
- The MCP server delivers the same nudge in agent-readable form: when the cache knows a newer
  version, the first successful tool result of a session carries a one-time trailing note, worded so
  the agent relays it — tell the user to run `p update`. Agent-driven users never see the CLI's
  stderr (`p mcp-serve`'s stderr goes to the host app's log file, not the conversation), so without
  this the people most likely to be running an old binary are exactly the ones who never hear about
  the fix. Same `P_NO_UPDATE_CHECK` opt-out.

### Changed

- `p doctor` and `p update --check` now resolve the latest release from the `Location` header of the
  `https://github.com/outline-insurance/mcp/releases/latest` redirect instead of the GitHub REST
  API. Unauthenticated REST calls are rate-limited to 60/hour per IP — an office NAT shares that
  budget across everyone behind it, and install.sh already documents the resulting failure as the
  normal one — while the redirect endpoint carries no such budget.

### Fixed

- Dev/local builds no longer report a false "update available" from `p doctor` and
  `p update --check`. The old comparison was string equality, so any non-release version string
  ("dev", a goreleaser snapshot) compared unequal to the published tag and read as out of date —
  telling every from-source build to install 0.0.x over itself, and training exactly the wrong users
  to ignore the nudge. Both commands now order versions numerically (MAJOR.MINOR.PATCH, so 0.0.10 >
  0.0.9) and fail closed: a non-release build prints an honest "comparison skipped (running dev
  build)" line instead of a fabricated verdict, and a local build ahead of the published release
  reads as up to date, not update-worthy.

## [0.0.22] - 2026-08-07

### Added

- Referral outcomes now carry their WHY. The risk summary (returned by `get_risk`, `submit_risk`,
  `resubmit_risk`, and `clone_submission`) selects and renders each submission's
  `referDeclineReasons` (as `reason:` lines) and `quotedReasons` (as `note:` lines), and a risk with
  any submission in REFERRED, UNDER_REVIEW, or CARRIER_REVIEW gets a one-line pointer: it is in
  human underwriting review, check `get_risk_activity`, do not resubmit to shake it loose.
  Previously a referral rendered as the bare status word — in the 0.0.21 incident five markets
  referred at once and the agent had nothing to distinguish "underwriting wants a look" from "your
  exposure data is wrong".
- SKILL.md gained a "When a submission refers" section: relay reasons verbatim, never invent a cause
  or present a referral as a decline, check activity for underwriting notes, resubmit only after
  changing something a reason names, and treat every-market-referred as a probable data error (wrong
  exposure unit) to re-check with the user.

## [0.0.21] - 2026-08-07

### Added

- Exposure-unit validation for the per-location "Class of business and exposure values" JSON. On
  percent-basis products (`cglV2`, `contractorsExcessStandalone`) each selected class's `value` must
  now be a number in 0–100 (a `%` suffix is normalized away); subcontracted-work classes
  (91581/91583/91585/91591) are exempt, as they take the annual $ cost of the subcontracted work.
  The risk's product id is fetched lazily — one extra query, only when a batch touches an exposure
  field. Motivation: a live partner agent wrote a $100,000 revenue figure where the percent of
  operations belonged; the server stores the value unvalidated and the rater multiplies payroll by
  `value/100`, so every market quoted at ~1000x ($877,451 instead of $877) or referred. Nothing in
  the flow ever surfaced the unit, making this the silent-failure twin of the free-text class-code
  and tenancy writes the tool already guards.

### Changed

- The exposure-values question hint and the SKILL.md exposure guidance now spell out the units:
  percent of operations on contractor GL products (never a dollar amount), $ cost for
  subcontracted-work classes, real amounts (sales/sqft/units/acres) elsewhere. SKILL.md previously
  said the basis was "payroll for contractor trades" — exactly the misreading that invites a dollar
  figure — and its example value was amount-sized.

## [0.0.20] - 2026-08-06

### Added

- MCP tool-call context now reaches the wire. The GraphQL client gained `WithContext` /
  `ExecuteContext`, and every per-operation timeout is now derived from the caller's context instead
  of a fresh `context.Background()` — so mcp-go's `notifications/cancelled`, which is what Claude
  Desktop sends when the user hits stop, now actually aborts the in-flight GraphQL request, the
  pre-request rate-limit wait, and presigned-S3 file transfers. Previously the stop was cosmetic:
  the user was told the call had been cancelled while the request ran on to completion or timeout
  with nothing able to abandon it.
- Per-request tool attribution: the MCP server now stamps `X-Client-Tool: <tool_name>` on every
  request, with the tool name carried in the request context by a `WithToolHandlerMiddleware`. This
  is the safe re-do of the attribution 0.0.17 deliberately left out: process-global state would
  cross-stamp tool names under mcp-go's five-worker stdio pool, and context scoping is exactly the
  request-scoped design that entry said it needed (PAR-5470, folded into ENG-895). The API server
  does not read this header yet — it reads only `x-client` — so this is client-side stamping today,
  not end-to-end observability; the server-side wiring is tracked on ENG-895.

### Changed

- A cancelled request now surfaces as the existing UNKNOWN-outcome guidance instead of a bare
  "context canceled": `client.TimeoutError` gained a `Canceled` flag, and the message reads
  "cancelled after Xs … THE OPERATION MAY HAVE COMPLETED SERVER-SIDE", with bind-class operations
  keeping their do-not-retry / `check_bind_readiness` guidance. The "raise `--timeout`" trailer is
  dropped for cancellations, where it is advice about the wrong knob — nothing timed out. Rationale:
  a cancelled `bindQuoteIssuePolicy` is exactly the "outcome UNKNOWN, not failed" case; a bare
  "cancelled" reads as "nothing happened" and invites the blind retry that turns one bind into two.

## [0.0.19] - 2026-08-05

### Added

- New `p install-desktop-config` command: discovers every Claude Desktop config location (macOS,
  Linux, and Windows — both MSIX app-container and classic layouts, without ever mistaking
  `%LOCALAPPDATA%\Claude`, the log directory, for a config dir), merges the `pathpoint` MCP server
  entry natively, and supports `--dry-run`. Merges preserve every other key and MCP server, treat
  empty files and `mcpServers: null` as fresh configs, and refuse — rather than clobber — files that
  don't parse, because this file also holds the app's own preferences. Writes are atomic
  (same-directory temp file + rename, preserving file mode) so a running Claude Desktop never sees a
  torn config. The behavior contract is ported from `install_test.ps1`'s cases into Go table tests
  in the new `desktop` package, which exercise the Windows branches on any development OS. This is
  also the fix for a moved or reinstalled binary: re-run it and the config points at the right place
  again.
- The macOS/Linux installer now puts `p` on PATH itself instead of printing a hint most users never
  acted on: when the install dir isn't on PATH it appends a marked, idempotent block to the shell's
  rc file (zsh/bash export; fish via `fish_add_path` in `conf.d`), telling the user what was written
  where. Re-runs — `p update` re-invokes the installer on every upgrade — detect the marker and
  never duplicate the block. The install dir is written single-quoted so nothing in an exotic
  `P_INSTALL_DIR` can execute at shell startup. Set `P_NO_MODIFY_PATH=1` to keep the installer out
  of rc files and get the old hint. This matters more than usual because the Claude Code plugin
  launches `p mcp-serve` by bare name from PATH.
- `p doctor` now checks client surfaces: whether the `claude` CLI is on PATH, whether Claude Desktop
  is present and its config wires the `pathpoint` MCP server, and whether that wiring points at a
  binary that still exists (a dangling command is flagged as a failure with a
  `p install-desktop-config` next step). When neither Claude Desktop nor Claude Code is found, it
  explains that the Pathpoint tools run locally over stdio, so claude.ai in a browser cannot reach
  them.

### Fixed

- The macOS/Linux installer no longer dies silently mid-install when a release's `checksums.txt`
  lacks an entry for the platform asset: under `set -euo pipefail` the no-match grep aborted the
  script between "Downloading..." and "Installed" with no output at all. All three checksum
  degradation cases (checksums.txt missing, asset entry missing, no local SHA-256 tool) now print a
  note naming the case and continue unverified — which also leaves the macOS quarantine flag in
  place, as before. A real hash mismatch still aborts the install. The asset lookup is now an exact
  string match rather than a regex, so dots in asset names can no longer match arbitrary characters.
- The Windows installer no longer aborts on PowerShell 7 when a release has no `checksums.txt` — the
  typed `WebException` catch never matched PS7's `HttpResponseException`. Every skipped-verification
  path (checksums missing, asset not listed, entry malformed) now says so instead of skipping
  silently.

### Changed

- `install.sh` and `install-local.sh` now delegate the Claude Desktop config write to
  `p install-desktop-config` instead of editing JSON with jq. The jq path required a tool many
  machines lack — stock macOS has no jq, so the least technical users got a JSON snippet and
  instructions to hand-edit their config — and it reported success even when jq failed on malformed
  user JSON (leaving a stray `.tmp` behind). The binary owns one merge implementation shared with
  Windows and reports its own outcome. When the call fails — including older pinned binaries that
  predate the subcommand — the installer says plainly that the config did not happen and prints the
  manual snippet; a config failure still never fails the install. jq is no longer used anywhere.
- Windows installer: `Unblock-File` (Mark-of-the-Web removal) now runs only when the download's
  SHA-256 matched the published checksum, mirroring install.sh's quarantine-clearing policy;
  unverified downloads keep the mark and the installer explains the first-run SmartScreen prompt and
  how to clear it.
- When Claude Desktop isn't detected, `install.sh` now names the exact config path it probed,
  suggests launching Claude Desktop once (it creates its config directory on first run), and prints
  the manual snippet — parity with the Windows installer, which previously offered all of that while
  Unix users got a single "skipping" line. When neither Claude Desktop nor the `claude` CLI is
  present, both installers' closing messages explain that the Pathpoint tools run locally over
  stdio, so claude.ai in a browser cannot reach them; the Windows installer's "nothing else is
  outstanding" claim — actively misleading for exactly that tester population — is gone. The final
  "Done." line is outcome-aware instead of unconditional.
- `install.sh` is restructured into functions behind a `BASH_SOURCE` main guard (with an explicit
  empty-`BASH_SOURCE` arm so the documented `curl | bash` one-liner still runs), with a new
  hand-rolled `install_test.sh` harness — sandbox HOMEs, shim `curl`/`p` binaries, bash
  3.2-compatible — covering checksum handling, desktop wiring, PATH writes, and a full sandboxed
  run. The Windows suite grew equivalent checksum and messaging cases (61 checks).
- Docs: the public README and landing pages now cover installer PATH setup (and its opt-out), native
  Claude Desktop wiring via `p install-desktop-config`, loud checksum degradation, and qualify the
  SmartScreen troubleshooting row to unverified downloads; removed a from-source build instruction
  that referenced the private monorepo. `release.sh` now refuses to cut a release if any user-facing
  mirrored file (installers, README, landing pages) references internal paths or `install-local`.

## [0.0.18] - 2026-08-05

### Changed

- The public site (GitHub Pages) now speaks to insurance agents rather than internal users, and
  gained a documentation page: `guide.html` carries getting-started setup, a conversation-first
  quote-to-bind walkthrough as the primary example, everyday-task recipes, an agent-scoped tool
  reference, and troubleshooting. The landing page's example conversation now shows the agent
  journey (submit → instant quotes → bind request) instead of manual quote entry, and internal-ops
  content was removed from the site. `release.sh` mirrors the new page with the same version
  substitution as the landing page.

## [0.0.17] - 2026-08-05

### Added

- `--confirm-prod` gate for CLI mutations. Every generated `p mutation` command, and any `p raw`
  document containing a mutation operation, now refuses to run against production without
  `--confirm-prod`. The classification is fail-closed (`client.RequiresProdConfirmation`, shared
  with the MCP guard so the two surfaces cannot drift): only endpoints recognisably NOT production —
  loopback and the `*.pathpoint.dev` estate — are waved through, so an unfamiliar host, a proxy, an
  IP literal, or a fully-qualified `api.app.pathpoint.com.` with the DNS root dot is asked about
  rather than silently allowed. Previously the MCP guard keyed on positive prod detection, which
  also meant any `pathpoint.com` hostname containing "demo" bypassed it — the same discipline the
  MCP tools have had via `confirm_prod`. `--yes` only skips the interactive prompt and no longer
  suffices on prod, so a non-interactive prod write names both flags. `p raw` mutations also gained
  the y/N confirmation (`--yes` to skip) that generated mutations already had; previously
  `p raw 'mutation {...}'` hit prod with no prompt of any kind. Mutation detection in `raw` scans
  for a top-level `mutation` keyword with comments and string literals stripped, and treats anything
  it cannot rule out as a mutation.
- `p doctor`: one-shot read-only diagnostic — build version, update availability, whether the `p` on
  PATH is the binary running, the saved session, and whether the server still accepts it. Exits
  non-zero when something needs fixing. Built for "run `p doctor` and paste the output" remote
  support.
- `p schema list` / `p schema describe` now work outside the monorepo. The merged GraphQL schema is
  embedded into the binary at codegen time (`gen/schema_embedded.go`) and is the only source these
  commands read — they answer for the binary in hand, so reading whatever checkout happened to be
  above the working directory would let an installed `p` describe operations it cannot run.
  Previously every installed binary failed with "could not find GraphQL schema files", which was the
  entire documented discovery path for external users.
- Generated flag help now carries the GraphQL type, a required marker, and JSON shape, e.g.
  `--claimIds  [UUID!]!, required (JSON array)` — previously flags rendered with no type and no
  required indication, and the only way to learn them was a runtime error.
- Request attribution: the `User-Agent` header carries the real build version (was hardcoded `1.0`)
  and `X-Client` distinguishes `p-mcp` (MCP server) from `p-cli` (direct CLI use), so API logs can
  answer "which release, driven by what" during an incident. Per-tool attribution (`X-Client-Tool`)
  was deliberately NOT included here: mcp-go's stdio transport runs a pool of five tool-call
  workers, so process-global state would stamp the wrong tool name whenever an agent issues parallel
  calls, and a header that is wrong under concurrency is worse than no header. It needed
  request-scoped context — shipped in 0.0.20 (PAR-5470, folded into ENG-895).

### Changed

- GraphQL errors now fail the process. A response whose body carries an `errors[]` array made the
  CLI exit 0; a permission denial or validation failure was indistinguishable from success by exit
  code, which is how a scripted `p mutation requestBind ... && next-step` runs the next step on a
  failed bind. The envelope is still printed to stdout; the process then exits non-zero
  (single-shot, `raw`, and bulk).
- Bulk runs (`--bulk-file`) no longer abort mid-file on the first transport error and no longer
  swallow per-item GraphQL errors. Output is strictly one NDJSON line per input item — a failed item
  keeps its slot, carrying the server's own `{"data": …, "errors": […]}` envelope when the server
  answered (partial data preserved), `{"error": …, "outcome": "failed"}` when the request never
  reached the server, or `{"error": …, "outcome": "unknown", "retry_safe": false}` on a client-side
  timeout — which may have completed server-side, and which an automated retry would otherwise turn
  into a duplicate bind. Each failure is reported to stderr with its item number, the run continues,
  and the exit code is non-zero if anything failed. `--fields` now applies to bulk runs (it was
  silently ignored), and an explicitly empty string flag value (`--flag ""`) is now sent instead of
  silently dropped.
- `get_login_status` (MCP) and `p login` now verify the saved session against the server instead of
  trusting the session file. A dead session used to report "Logged in" from the MCP tool — a false
  green light the agent only discovered on its next real call — and `p login` short-circuited to the
  same lie, so the documented recovery ("run `p login`") did nothing without a manual `p logout`
  first. Now the status tool reports NOT logged in with the recovery step, and `p login`
  re-authenticates a stale session in place, against the stale session's own environment unless
  `--endpoint` says otherwise.
- The MCP `login` tool now opens the browser sign-in itself instead of returning a `p login` command
  for the user to run in a terminal. The browser flow moved out of `cmd` into a shared `login`
  package (mcp cannot import cmd without a cycle, and the logIn mutation document must stay out of
  package mcp for the AST-derived read/write classification to keep `login` read-only), and the tool
  starts it in-process: the window stays open for 5 minutes, a wrong password re-renders the form
  rather than ending the flow, and the result text carries the form URL for when the window is not
  visible. Credentials still never pass through the tool, the transcript, or the MCP transport — the
  form posts to a localhost listener that performs the GraphQL exchange directly. One sign-in at a
  time per server: a second `login` call while one is pending reports the pending window's URL, age
  and environment instead of opening another (and says so explicitly when the pending window targets
  a different environment than the one requested); a call for an environment the saved session
  already covers verifies with the server and answers "already logged in" with no browser; an
  unreachable server gets a retry-shortly answer, not a browser window whose submit would fail the
  same way. When the browser cannot be opened, the text leads with that failure and falls back to
  the URL plus the terminal command. `get_login_status` is now in-flight-aware: not-logged-in
  answers also report a pending browser sign-in (URL, age, total window), a sign-in that expired or
  failed is surfaced exactly once with the reason and the advice to call `login` again, and its
  stale "run `p login` in a terminal" recovery advice now points at the `login` tool. Because the
  tool now performs the credential exchange in-process, the MCP `environment` argument is
  constrained to Pathpoint environments (named `local`/`demo`/`prod` or a loopback / `pathpoint.dev`
  / `pathpoint.com` host, https for non-loopback) — an untrusted, prompt-injectable argument can no
  longer point the sign-in form at an arbitrary host and exfiltrate the password; arbitrary
  endpoints remain available on the trusted CLI `--endpoint` flag. The GraphQL client also no longer
  follows cross-host redirects, so an open redirect on an allowed host cannot forward credentials
  off-box.
- The shared 2-requests/second client-side rate limit now actually applies across an MCP session. It
  was tracked per client instance while every tool call constructs a fresh client, making it a no-op
  exactly where it mattered. Now process-wide; localhost endpoints are exempt.
- `p mcp-serve` refuses `--timeout`: an explicit timeout collapses every per-operation budget to one
  number, silently re-introducing the timed-out-bind-reports-failure problem the budget table exists
  to prevent.
- Errors print once. Cobra's default error handling printed every error twice with a usage dump in
  between; now the message appears once, prefixed `Error:`.
- `install.sh`: the "could not resolve latest version" explanation is now reachable (a curl failure
  inside the command substitution aborted the script under `set -e` before the hint printed — and
  that failure is the normal GitHub-API rate-limit case, now spelled out with the `P_VERSION`
  workaround); the macOS quarantine attribute is cleared on install so Gatekeeper doesn't kill the
  unsigned binary on first run; the closing message names `p update` and `p doctor`.
- Landing page and public README: corrected stale counts (85 MCP tools, 91 queries / 158 mutations),
  stopped steering external users to the internal `demo`/`local` environments (login examples now
  use the prod default), documented `p update` and `p doctor`, updated the session-expired fix to
  plain `p login`, and added a report-an-issue link with a no-policyholder-data-in-public-issues
  caution.

## [0.0.16] - 2026-08-04

### Added

- Claude Code plugin distribution. The public release repo now doubles as a Claude Code plugin
  marketplace: `release.sh` assembles `.claude-plugin/marketplace.json` (marketplace
  `outline-insurance`) and a `plugins/pathpoint/` plugin — `.claude-plugin/plugin.json` plus the
  skill at `skills/pathpoint/SKILL.md` — into the public-repo mirror at release time. The plugin
  also declares the `p mcp-serve` MCP server (run as `p` from PATH), so a plugin install gives
  Claude Code the skill and the tools together — previously the installers only wired the MCP server
  into Claude Desktop and Claude Code got the skill alone. The plugin's version is stamped from
  `RELEASE_VERSION` via the existing `__P_VERSION__` substitution, so `claude plugin update` sees a
  new version exactly when a release is cut and there is no second hand-maintained version. The
  monorepo keeps its flat `skills/SKILL.md` as the single source of truth (`mcp/skill_md_test.go`
  still reads `../skills/SKILL.md`); the plugin directory shape exists only in the mirror.
- `release.sh --dry-run`: stages the public-repo mirror in `dist/public-mirror` with no goreleaser
  build, no `gh` access, and nothing pushed, then validates the assembled
  `marketplace.json`/`plugin.json` (JSON well-formedness via python3 when present; manifest schema,
  plugin layout, and skill frontmatter via `claude plugin validate`). Real releases hard-require the
  `claude` check and abort before anything ships; only `--dry-run` may fall back to the JSON-syntax
  check alone.
- `install.sh` / `install.ps1`: when a `claude` executable is on PATH, the installers register the
  marketplace by explicit HTTPS URL (the `owner/repo` shorthand clones over SSH, which most users
  haven't set up for GitHub) and install `pathpoint@outline-insurance` at user scope, falling back
  to `marketplace update` / `plugin update` when already registered or installed. When the plugin is
  installed and enabled (checked via `claude plugin list --json` — a disabled plugin doesn't count),
  the plain skill copy earlier installers wrote to `~/.claude/skills/Pathpoint/` is moved aside to
  `SKILL.md.bak` — moved, not deleted, in case it was customized — so the skill isn't loaded twice;
  on any failure (no `claude`, older CLI, network) they fall back to that plain copy exactly as
  before. Plugin installation is best-effort and never fails the binary install. Pinned installs
  (`P_VERSION` set) skip the plugin — it tracks the latest release by design — and install the
  pinned release's own skill copy; if the plugin is already installed it stays (an installer
  shouldn't uninstall it behind the user's back) and the installer prints the exact uninstall
  command needed to pin fully. Before touching the marketplace, the installers also verify that a
  registered `outline-insurance` marketplace actually points at this repo — `marketplace update` and
  `plugin install` address it by name alone, so a name-squatted marketplace from another source is
  refused outright (with the remove command printed) and the plain skill is used instead.

### Changed

- The landing page and the generated public README document the plugin flow for Claude Code users.
  The `pathpoint-skill.zip` import path stays documented for claude.ai and Claude Desktop, which
  don't support plugins.
- `release.sh` creates the GitHub release before pushing the public-repo mirror. The pushed mirror
  advertises the new plugin version, so a failed release after the push would leave the marketplace
  permanently pointing at binaries that don't exist; the reverse partial failure (release exists,
  push failed) just pairs the new binary with the previous plugin until the push is retried with the
  new `--sync-only` mode, which re-assembles and pushes the mirror for an existing release without
  rebuilding. Every release records the monorepo commit it was cut from as a hidden comment in its
  release notes, and `--sync-only` refuses to run unless HEAD matches it — combined with the
  clean-tree check this pins every mirrored input (installers, plugin metadata, landing page) to the
  release's revision, not just the skill; releases predating the stamp fall back to comparing
  SKILL.md against the release asset. The clean-tree preflight also switched from `git diff` to
  `git status --porcelain` so untracked files (the plugin templates are read straight from the
  working tree) block a release too.

## [0.0.15] - 2026-08-04

### Added

- `update_policy_dates` (core): change the policy effective/expiration dates on a quoted risk — the
  post-quote path the web app's subjectivities page uses (`updatePolicyDates`). Updates the
  application and the quote, recalculates the grace period, and queues a Novidea update; it does not
  re-rate. Operates on the risk's selected quote only (the mutation rewrites the risk-wide
  application dates alongside the quote's, so a non-selected target would desync the two), refuses
  bound quotes (post-bind date changes are endorsements), and shows old → new dates. Reports failure
  unless the payload's `success` flag is actually true.
- `undo_bind` (policy toolset): the ops correction for a mistaken bind (`undoBindIssueQuote`, admin
  only). Clears the quote's bound/issued state and deletes the Bound/Issued activity rows — the tool
  spells out that the deletion is unrecoverable, refuses quotes that are not bound, and shows the
  policy state before and after.
- `search_agencies` and `set_agency_commission` (admin toolset): read and set per-agency commission
  percentages (`agencies` / `updateAgency`, both `GLOBAL_MANAGE_AGENCY`). Search takes SQL LIKE name
  patterns and prints each agency's `groupId`, both commission percentages and network membership.
  The setter only ever sends the two commission fields — `updateAgency`'s network-reassignment
  cascade (which overrides commission inputs with network defaults) is structurally unreachable, and
  a registry test pins that. Values are validated to the database's (0, 15] range before the
  mutation runs — the resolver writes the unconstrained legacy groups row before the constrained
  agencies row, so a server-side rejection would half-apply — and 0 is refused with its own message:
  the resolver's Novidea enqueue drops falsy values, so a zero would land in Pathpoint but leave
  Novidea at the old rate.
- Coterie in `markets.go`: the carrier landed in `shared/constants` (PAR-4658) without the `p`-side
  mirror, so `quote_risk`/`select_markets` rejected it and two parity tests were failing. Added the
  alias and market UUID.

### Changed

- The sentence "Pass confirm_prod=true when the active session is pointed at prod." was removed from
  every tool description that carried it (~20). It duplicated the `confirm_prod` parameter's own
  description inside the same tool JSON, and the ~1.2 KB it cost was what pushed the core tools/list
  payload over its 60 KB budget when `update_policy_dates` joined core.

- Generated `p mutation <name>` commands now say which environment they will hit. The confirmation
  prompt reads `About to run mutation <name> against <env>. Continue? [y/N]`, and when the prompt is
  skipped with `--yes` a `Running mutation <name> against <env>` line is printed to stderr instead,
  so a mutation can never run without the target environment being shown.

## [0.0.14] - 2026-08-03

### Added

- `quote_risk` and `update_quote` now take `includes_wind` and `est_cost_wind`, mapping to
  `QuoteOptions.includesWind` and `QuoteOptions.estCostWind`. Wind coverage and the wind portion of
  the premium were previously unreachable from the MCP: a quote could be written but its wind fields
  could not, so a quote carrying a wind component had to be finished in the app.
- Both parameters are routed off pointers rather than off the zero-value rule the fee parameters
  follow, because for wind a zero is a real instruction rather than an absent one. Omitting a
  parameter leaves the existing value alone — the key is not sent at all — but
  `includes_wind: false` is sent, and is the only way to drop wind coverage from a quote, and
  `est_cost_wind: 0` is sent, and is the only way to clear a wind cost that was already set. This is
  deliberately unlike `agency_fee`, `tria` and the other fee parameters, where a 0 is
  indistinguishable from "not supplied" and is dropped. A new `optionalFloat` helper implements it,
  alongside the existing `optionalBool`.
- `est_cost_wind` is validated rather than coerced-or-dropped. A value that is present but is not a
  number (`"lots"`, `true`, `null`, an overflowing literal like `"1e400"`, or a non-finite `NaN` /
  `Inf`) now fails the call with `est_cost_wind must be a number, got "lots"`. It previously read as
  "absent", so `update_quote {premium: 1234, est_cost_wind: "lots"}` wrote the premium, discarded
  the wind cost, and reported success.
- `get_quote` reads both values back, so the wind fields appear in the quote detail output and a
  before/after on an `update_quote` can actually be shown.

### Changed

- The default `core` payload grows from 58,536 to 59,104 bytes as the four new parameters land on
  two core tools, leaving 896 bytes under the 60,000-byte budget. Nothing moved out of core to make
  room, and at this margin the next core tool of average size (~1,040 bytes) does not fit.

### Fixed

- The Windows installer reported "Claude Desktop not detected" and skipped MCP setup on machines
  where `%APPDATA%\Claude` doesn't exist, leaving `p.exe` installed but unreachable from Claude
  Desktop. Adding the config by hand didn't help either, for a separate reason: Claude Desktop now
  ships as an MSIX package that runs in an app container, so when it reads `%APPDATA%\Claude`
  Windows redirects that to the package's private cache. The file it actually reads is
  `%LOCALAPPDATA%\Packages\Claude_<hash>\LocalCache\Roaming\Claude\claude_desktop_config.json`. The
  installer now probes both layouts and writes each one it finds.
- Two paths look correct and do nothing, which is what made this hard to diagnose:
  `%LOCALAPPDATA%\Claude\` is the _log_ directory, and Settings → Developer → "Edit Config" opens
  the non-virtualized `%APPDATA%` copy that the containerized app never reads.
- The config is now written as UTF-8 without a BOM. `Set-Content -Encoding UTF8` emits one on
  Windows PowerShell 5.1, and a leading BOM makes `JSON.parse` throw, so the app behaved as though
  there were no config at all.
- An existing config that isn't valid JSON is no longer clobbered, and no longer aborts the
  installer. The MSIX file also holds Claude Desktop's own preferences, so it is merged, never
  overwritten.
- The "wire it up by hand" fallback emitted invalid JSON: the executable path was interpolated raw,
  so `C:\Users\...` contained the illegal escape `\U` and the printed config was rejected by the
  app. It is now escaped properly, and says to merge the `pathpoint` entry rather than replace the
  file.
- A locked or unwritable config no longer aborts the whole install at the first candidate; each is
  attempted and failures are reported per target. The closing message reflects what actually
  happened instead of always printing "Done".

## [0.0.13] - 2026-07-26

### Added

Twelve tools closing capability gaps between the web app and the MCP. Each wraps a GraphQL operation
the web frontend already uses; none required a server change.

- `search_addresses` and `set_property_geocode` — resolve a street address to real candidates before
  writing it, then store latitude, longitude and county on the property. Addresses written with
  `modify_submission` were previously stored exactly as typed, with no county or coordinates for
  appetite and hazard scoring to read. `set_property_geocode` writes despite the underlying API call
  being shaped like a read, so it is guarded like any other write.
- `get_recommended_class_codes` and `get_recommended_tenancy_types` — AI class-code and tenancy
  suggestions derived from a risk's own answers and documents, ranked by confidence. Additive to the
  keyword-based `search_class_codes` / `search_tenancy_types`, which remain unchanged. Only matches
  scoring 0.8+ are returned, so an empty result is ambiguous rather than a verdict, and both tools
  say so.
- `select_markets` — choose which markets a not-yet-submitted risk goes to, by carrier name or UUID.
  Write-only by necessity: no query in the API returns a risk's current market selection, so the
  tool states plainly that it cannot show or verify current state.
- `list_recoverable_drafts` — find never-submitted drafts to resume, which `list_risks` does not
  surface. The default 7-1 day window excludes the last 24 hours; pass `days_ago_end: 0` for today.
- `add_risk_note` — the write side of `get_risk_activity`. Always a `COMMENT`, and deliberately
  offers no way to write the lifecycle activity types, since minting one would fake a state change
  in the audit trail. Notes are permanent: nothing can edit or delete them.
- New opt-in `claims` toolset — `list_pending_claims`, `flag_pending_claim`, `add_property_claim`
  and `delete_property_claims`. Loss history drives pricing and was previously unreachable. Two
  unrelated concepts are both called "claim" here and the tools describe themselves as distinct:
  `flag_pending_claim` is a post-quote underwriting marker whose renewal cascade de-selects and
  hides renewal quotes, while `add_property_claim` adds an empty loss-history row to a building.
  `delete_property_claims` has no undo.
- New opt-in `hazard` toolset — `order_wildfire_scores`. Queues a billable CoreLogic order and files
  the report into Novidea. Internal ops/QA work; success means only that the job was queued, and
  there is no way to check completion.

### Changed

- The default `core` payload grows from 49,861 bytes / 49 tools to 58,536 bytes / 56 tools as seven
  of the twelve new tools land in core, leaving 1,464 bytes under the 60,000-byte budget. The
  `claims` and `hazard` groups are opt-in, which is partly a judgement about scope — loss history
  and paid vendor orders are not the everyday intake→bind loop — and partly the budget doing the
  deciding. `toolsets.go` records both reasons, and notes that `list_pending_claims` should move
  back to core if the budget is ever raised. For whoever hits the ceiling next: moving `claims` back
  to core costs ~7,300 bytes and `hazard` ~2,100, so neither fits today, and the next core tool of
  average size (~1,040 bytes) very nearly does not either.
- SKILL.md's "Not covered by these tools" section was understating the gap: it listed only e-signing
  and MTA. It now names what is genuinely absent — the MTA wizard, the e-sign ceremony, premium
  financing, state surplus-lines subjectivity forms, policy-date changes on a bound quote, extracted
  document field values, creating broker users, and risk import.

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
