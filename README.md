# Pathpoint MCP Server

Install the Pathpoint `p` CLI + Claude MCP server + Pathpoint skill on your machine.

Current release: **v0.0.15** &nbsp;·&nbsp; [Website](https://outline-insurance.github.io/mcp/) &nbsp;·&nbsp; [All releases](https://github.com/outline-insurance/mcp/releases) &nbsp;·&nbsp; [Changelog](CHANGELOG.md)

## Install

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/outline-insurance/mcp/main/install.sh | bash
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/outline-insurance/mcp/main/install.ps1 | iex
```

The installer:

- Downloads the latest pre-built `p` binary for your platform
- Puts it in a per-user directory (`~/.local/bin` on macOS/Linux, `%LOCALAPPDATA%\Pathpoint` on Windows)
- Installs the Pathpoint skill into Claude Code (`~/.claude/skills/Pathpoint/`)
- Adds the `p mcp-serve` entry to your Claude Desktop config

Re-run to upgrade. Pin a specific version with `P_VERSION=x.y.z` (bash) or `$env:P_VERSION='x.y.z'` (PowerShell).

On Windows, SmartScreen will warn you once per version (the binary is unsigned) — click "More info → Run anyway".
On macOS, if you see a Gatekeeper warning, clear the quarantine flag: `xattr -d com.apple.quarantine "$(which p)"`.

## What's in each release

| Asset | What it is |
|-------|------------|
| `p_<ver>_darwin_<arch>.tar.gz` | macOS binary (amd64, arm64) |
| `p_<ver>_linux_<arch>.tar.gz`  | Linux binary (amd64, arm64) |
| `p_<ver>_windows_<arch>.zip`   | Windows binary (amd64, arm64) |
| `checksums.txt`                | SHA-256 for every archive |
| `SKILL.md`                     | Pathpoint skill source (also mirrored at repo root) |
| `pathpoint-skill.zip`          | Skill packaged for Claude Desktop / Claude.ai Web |

## Pathpoint skill

The skill is a guide Claude reads so it knows how to walk non-technical users through Pathpoint operations (quoting, submissions, risk management). The install script sets it up automatically for Claude Code. For Claude Desktop or Claude.ai Web you import the zip manually.

### Claude Code (auto)

Installed by the script at `~/.claude/skills/Pathpoint/SKILL.md`. Manual install:

```bash
mkdir -p ~/.claude/skills/Pathpoint
curl -fsSL https://raw.githubusercontent.com/outline-insurance/mcp/main/SKILL.md \
  -o ~/.claude/skills/Pathpoint/SKILL.md
```

### Claude Desktop / Claude.ai Web (manual zip import)

Claude Desktop skills live on Anthropic's servers rather than a local path, so the final step is manual. The installer already helps: it pre-downloads `pathpoint-skill.zip` to your `Downloads` folder when it detects Claude Desktop.

1. Open Claude Desktop.
2. **Settings → Capabilities → Skills → Create skill** → upload `~/Downloads/pathpoint-skill.zip` (or `%USERPROFILE%\Downloads\pathpoint-skill.zip` on Windows).
3. Restart Claude Desktop, or start a fresh chat on Claude.ai Web.

If you're on Claude.ai Web or installed before this step was added, you can grab the zip directly from the [latest release](https://github.com/outline-insurance/mcp/releases/latest).

## Authenticating

```bash
p login --endpoint demo    # or: local, prod, or a full URL
```

This opens a local browser form (served on `127.0.0.1` with a per-run nonce and loopback Host check). Your password is never typed into the terminal and never leaves your machine except to call the Pathpoint auth endpoint directly. The session is saved to `~/.config/p/session.json` (or `%USERPROFILE%\.config\p\session.json` on Windows) with mode `0600`.

For CI / non-interactive:

```bash
p login --endpoint demo --email you@pathpoint.com --password <pw>
# or
P_EMAIL=you@pathpoint.com P_PASSWORD=<pw> p login --endpoint demo
```

## Manual install

If the one-liner doesn't fit your environment:

1. Download the right archive from the [latest release](https://github.com/outline-insurance/mcp/releases/latest).
2. Unpack it and put `p` somewhere on your PATH.
3. Add the MCP entry to your Claude Desktop config:
   ```json
   {
     "mcpServers": {
       "pathpoint": {
         "command": "/path/to/p",
         "args": ["mcp-serve"]
       }
     }
   }
   ```
   Config location:
   - macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
   - Linux: `~/.config/Claude/claude_desktop_config.json`
   - Windows: `%APPDATA%\Claude\claude_desktop_config.json`

   On Windows, don't trust that path blindly. The MSIX build of Claude Desktop runs in an app
   container and actually reads
   `%LOCALAPPDATA%\Packages\Claude_<hash>\LocalCache\Roaming\Claude\claude_desktop_config.json`.
   Two traps to know about:
   - Settings → Developer → **Edit Config** opens the *non-virtualized* `%APPDATA%\Claude\` copy
     on MSIX installs, which the app never reads. Editing what that button opens does nothing.
   - `%LOCALAPPDATA%\Claude\` is the *log* directory, not a config directory.

   To find the file the app really reads:
   ```powershell
   Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory |
     Where-Object { $_.Name -match '(^|\.)Claude_' } |
     ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude_desktop_config.json' }
   ```
   If that returns nothing, you have a classic install and `%APPDATA%\Claude\` is correct.
4. Restart Claude Desktop.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Windows SmartScreen warning | Click "More info → Run anyway". One-time per version. |
| Windows: "Claude Desktop not detected" | Launch Claude Desktop once, then re-run the installer. It creates its config directory on first run. |
| Windows: installer says it configured the MCP server, but `pathpoint` isn't in Connectors | Fully quit Claude Desktop (tray icon too) and reopen — the config is read only at startup. If it's still missing, check the path the installer printed against the "Manual install" note above; on MSIX installs the config lives under `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\`, not `%APPDATA%`. |
| macOS "developer cannot be verified" | `xattr -d com.apple.quarantine "$(which p)"` once. |
| `p login` doesn't open a browser | Paste the URL from the terminal into any browser on the same machine. |
| Session expired | `p logout` then `p login --endpoint <env>` again. |

## Source

`p`'s source lives in the private Pathpoint monorepo. This repo hosts release artifacts, install scripts, and the skill only.
