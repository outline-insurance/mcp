# Changelog

All notable changes to the `p` CLI are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.9] - 2026-06-24

### Added

- WKFC Underwriting Managers is now a recognized carrier in the MCP server. Quote and resubmit tools
  resolve `WKFC` (or "WKFC Underwriting Managers") to its market and UUID, matching the carrier
  added to the product in #15570.
- A public landing page for the MCP server (served via GitHub Pages from the release repo).

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
