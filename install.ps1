# Install the Pathpoint `p` CLI on Windows.
#
# Usage (one-liner):
#   irm https://raw.githubusercontent.com/outline-insurance/mcp/main/install.ps1 | iex
#
# If your execution policy blocks scripts:
#   powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/outline-insurance/mcp/main/install.ps1 | iex"
#
# Env overrides:
#   P_REPO         Public release repo (default: outline-insurance/mcp)
#   P_VERSION      Version to install, e.g. "0.1.0" (default: latest)
#   P_INSTALL_DIR  Where to drop p.exe (default: %LOCALAPPDATA%\Pathpoint)
#   P_SKILL_DIR    Claude Code skill dir (default: %USERPROFILE%\.claude\skills\Pathpoint)

$ErrorActionPreference = 'Stop'

$Repo          = if ($env:P_REPO)     { $env:P_REPO }        else { 'outline-insurance/mcp' }
$Version       = if ($env:P_VERSION)  { $env:P_VERSION }     else { 'latest' }
$PinnedVersion = [bool]$env:P_VERSION
$InstallDir = if ($env:P_INSTALL_DIR) { $env:P_INSTALL_DIR } else { "$env:LOCALAPPDATA\Pathpoint" }
$SkillDir   = if ($env:P_SKILL_DIR)   { $env:P_SKILL_DIR }   else { "$env:USERPROFILE\.claude\skills\Pathpoint" }

$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }

# ---------------------------------------------------------------------------
# Claude Desktop config discovery
#
# Anthropic documents one path -- %APPDATA%\Claude\claude_desktop_config.json --
# but the current Windows build ships as an MSIX package that runs inside an app
# container. When that app reads %APPDATA%\Claude, Windows silently redirects it
# to the package's private LocalCache, so the documented file is never read. Two
# different layouts therefore exist in the wild:
#
#   MSIX     %LOCALAPPDATA%\Packages\Claude_<hash>\LocalCache\Roaming\Claude\
#   classic  %APPDATA%\Claude\
#
# Note that %LOCALAPPDATA%\Claude\ is the *log* directory on both. Dropping a
# config next to those logs looks right and does nothing.
# ---------------------------------------------------------------------------

# Every directory Claude Desktop might read a config from on this machine, most
# authoritative first. Empty means Claude Desktop was not found at all.
function Get-ClaudeConfigDirs {
    $dirs = @()

    $pkgRoot = [System.IO.Path]::Combine("$env:LOCALAPPDATA", 'Packages')
    if (Test-Path -LiteralPath $pkgRoot) {
        # Directories here are named by PackageFamilyName ("Claude_<publisher hash>"),
        # but match loosely: an over-tight pattern is what made the previous
        # version of this script miss the install entirely. Requiring a "Claude_"
        # component still rejects neighbours like "ClaudeCodeHelper_<hash>".
        $pkgs = @(Get-ChildItem -LiteralPath $pkgRoot -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '(^|\.)Claude_' })
        foreach ($pkg in $pkgs) {
            $dirs += [System.IO.Path]::Combine($pkg.FullName, 'LocalCache', 'Roaming', 'Claude')
        }
    }

    $roaming = [System.IO.Path]::Combine("$env:APPDATA", 'Claude')
    if (Test-Path -LiteralPath $roaming) { $dirs += $roaming }

    # The app has run at least once (this is the log dir) but neither config
    # layout is present yet. Fall back to the documented path.
    if ($dirs.Count -eq 0) {
        $logs = [System.IO.Path]::Combine("$env:LOCALAPPDATA", 'Claude', 'Logs')
        if (Test-Path -LiteralPath $logs) { $dirs += $roaming }
    }

    return $dirs
}

# Build a hashtable from a parsed JSON object. Avoids ConvertFrom-Json
# -AsHashtable, which doesn't exist on Windows PowerShell 5.1 -- the runtime
# that ships with stock Windows and the most likely host for this
# `irm | iex` one-liner.
function ConvertTo-PSHashtable($obj) {
    if ($null -eq $obj) { return [ordered]@{} }
    $h = [ordered]@{}
    foreach ($prop in $obj.PSObject.Properties) {
        $v = $prop.Value
        if ($v -is [System.Management.Automation.PSCustomObject]) {
            $h[$prop.Name] = ConvertTo-PSHashtable $v
        } else {
            $h[$prop.Name] = $v
        }
    }
    return $h
}

# The config block to print when we can't write the file ourselves.
#
# The only part that needs escaping is the path -- dropped into a string raw, a
# Windows path is invalid JSON (C:\Users contains the illegal escape \U), so
# anyone following the instructions would paste a config the app rejects. Run it
# through ConvertTo-Json, which returns a complete JSON string literal (quotes
# included), and hand-write the rest. Writing the array literal by hand also
# means Windows PowerShell 5.1 can't collapse it to a scalar the way it can when
# serializing a whole object.
function Get-ManualConfigSnippet([string]$ExePath) {
    $cmd = $ExePath | ConvertTo-Json
    return @"
{
  "mcpServers": {
    "pathpoint": {
      "command": $cmd,
      "args": ["mcp-serve"]
    }
  }
}
"@
}

# Merge the pathpoint MCP server entry into the config in $ConfigDir, preserving
# everything else already in the file. Returns the path written, or $null.
function Set-PathpointMcpServer([string]$ConfigDir, [string]$ExePath) {
    $cfgPath = [System.IO.Path]::Combine($ConfigDir, 'claude_desktop_config.json')

    $cfg = [ordered]@{}
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $raw = Get-Content -LiteralPath $cfgPath -Raw
            if ($raw -and $raw.Trim()) { $cfg = ConvertTo-PSHashtable ($raw | ConvertFrom-Json) }
        } catch {
            # The MSIX config also holds the app's own preferences. Refuse to
            # clobber a file we can't parse.
            Write-Warning "Not valid JSON, leaving it alone: $cfgPath"
            Write-Warning "Fix or delete that file and re-run this installer."
            return $null
        }
    }

    if (-not ($cfg['mcpServers'] -is [System.Collections.IDictionary])) {
        $cfg['mcpServers'] = [ordered]@{}
    }
    $cfg['mcpServers']['pathpoint'] = [ordered]@{
        command = $ExePath
        args    = @('mcp-serve')
    }

    # Windows PowerShell 5.1 can collapse a single-element array to a bare
    # scalar. If that ever happens to "args" the entry is malformed and Claude
    # Desktop drops the server without saying why, so check rather than trust.
    # Serialize our entry on its own -- scanning the merged document would let
    # some other server's "args" array satisfy the check for us.
    $entryJson = $cfg['mcpServers']['pathpoint'] | ConvertTo-Json -Depth 5
    if ($entryJson -notmatch '"args"\s*:\s*\[') {
        Write-Warning "Refusing to write a malformed MCP entry to $cfgPath (""args"" did not serialize as a JSON array on PowerShell $($PSVersionTable.PSVersion))."
        return $null
    }

    $json = $cfg | ConvertTo-Json -Depth 10

    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    # UTF-8 with no BOM. `Set-Content -Encoding UTF8` writes a BOM on Windows
    # PowerShell 5.1, and a leading BOM makes JSON.parse throw -- the app then
    # behaves as though there were no config at all.
    [System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $cfgPath
}

# Run the claude CLI with all output suppressed; $true on exit code 0.
# $ErrorActionPreference is 'Stop' script-wide, and on Windows PowerShell 5.1
# redirecting a native command's stderr under 'Stop' turns any stderr line
# into a terminating NativeCommandError even when the command succeeds -- so
# drop to 'Continue' for the duration of the call.
function Invoke-ClaudeQuiet {
    param([string[]]$CliArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & claude @CliArgs *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}

# Returns the pathpoint plugin's actual state: 'enabled', 'disabled',
# 'absent', or 'unknown' when it can't be determined (e.g. a claude CLI
# without `plugin list --json`). Callers treat the states asymmetrically: a
# disabled plugin must not suppress the plain-skill fallback (the user would
# be left with no active skill), while 'unknown' must not override a
# successful install (that would hand out duplicate skills instead).
function Get-PathpointPluginState {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = (& claude plugin list --json 2>$null) | Out-String
        if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) { return 'unknown' }
        # The plugin can be installed at several scopes at once; if any entry
        # is enabled the skill will load, so that is the effective state.
        $entries = @(@($raw | ConvertFrom-Json) | Where-Object { $_.id -eq 'pathpoint@outline-insurance' })
        if ($entries.Count -eq 0) { return 'absent' }
        if (@($entries | Where-Object { $_.enabled }).Count -gt 0) { return 'enabled' }
        return 'disabled'
    } catch {
        return 'unknown'
    } finally {
        $ErrorActionPreference = $prev
    }
}

# Which source the registered 'outline-insurance' marketplace points at:
# 'ours' (some field references this repo), 'other' (the name is taken by a
# different source), 'absent', or 'unknown' when it can't be determined.
# Only 'other' changes behavior -- the installer must not refresh or trust
# a marketplace it didn't register, since `marketplace update` and
# `plugin install` address it by name alone.
function Get-PathpointMarketplaceState {
    param([string]$ExpectedRepo)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = (& claude plugin marketplace list --json 2>$null) | Out-String
        if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) { return 'unknown' }
        # Strict equality against known source shapes -- substring matching
        # would let a hostile URL like https://evil.example/outline-insurance/mcp
        # pass. A legitimate-but-unrecognized shape reads as 'other', which
        # only costs the plugin path (the plain skill still installs).
        $repoNorm = $ExpectedRepo.Trim().ToLowerInvariant()
        $normalize = {
            param($v)
            $s = "$v".Trim().ToLowerInvariant().TrimEnd('/')
            if ($s.EndsWith('.git')) { $s = $s.Substring(0, $s.Length - 4) }
            return $s
        }
        $expected = @(
            $repoNorm,
            "https://github.com/$repoNorm",
            "http://github.com/$repoNorm",
            "git@github.com:$repoNorm",
            "ssh://git@github.com/$repoNorm"
        )
        foreach ($m in @($raw | ConvertFrom-Json)) {
            if ($m.name -eq 'outline-insurance') {
                if ((& $normalize $m.source) -eq 'github' -and (& $normalize $m.repo) -eq $repoNorm) { return 'ours' }
                foreach ($v in $m.PSObject.Properties.Value) {
                    if ($v -is [string] -and $expected -contains (& $normalize $v)) { return 'ours' }
                }
                return 'other'
            }
        }
        return 'absent'
    } catch {
        return 'unknown'
    } finally {
        $ErrorActionPreference = $prev
    }
}

# Resolve "latest" via the GitHub API.
if ($Version -eq 'latest') {
    try {
        $tag = (Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing).tag_name
        $Version = $tag -replace '^v', ''
    } catch {
        Write-Error "Could not resolve latest version from $Repo. Is the repo public? ($_)"
        exit 1
    }
}

$Asset   = "p_${Version}_windows_${Arch}.zip"
$BaseUrl = "https://github.com/$Repo/releases/download/v$Version"

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null
try {
    $ZipPath = Join-Path $Tmp $Asset

    Write-Host "Downloading p $Version (windows/$Arch)..."
    Invoke-WebRequest -Uri "$BaseUrl/$Asset" -OutFile $ZipPath -UseBasicParsing

    # Verify checksum if checksums.txt is published.
    try {
        $checksumsPath = Join-Path $Tmp 'checksums.txt'
        Invoke-WebRequest -Uri "$BaseUrl/checksums.txt" -OutFile $checksumsPath -UseBasicParsing -ErrorAction Stop
        $line     = Get-Content $checksumsPath | Where-Object { $_ -match [regex]::Escape($Asset) + '$' } | Select-Object -First 1
        if ($line) {
            $expected = ($line -split '\s+')[0].ToLower()
            $actual   = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLower()
            if ($expected -ne $actual) {
                throw "Checksum mismatch for ${Asset}: expected $expected, got $actual"
            }
        }
    } catch [System.Net.WebException] {
        # checksums.txt not published — skip silently.
    }

    # Install binary.
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $ExePath  = Join-Path $InstallDir 'p.exe'
    $OldExe   = "$ExePath.old"

    # Clean up any stale p.exe.old left from a previous self-update.
    if (Test-Path $OldExe) {
        try { Remove-Item -Force $OldExe -ErrorAction Stop } catch { }
    }

    # If this install is being run as `p update`, the currently running
    # p.exe holds an exclusive lock and Expand-Archive will fail. Windows
    # DOES let us rename a running executable out of the way, so move it
    # aside first; the new p.exe extracts cleanly next to it.
    if (Test-Path $ExePath) {
        try {
            Rename-Item -Path $ExePath -NewName 'p.exe.old' -ErrorAction Stop
        } catch {
            Write-Error "Could not move existing $ExePath aside (is it running in another window?). Close it and re-run."
            throw
        }
    }

    Expand-Archive -Path $ZipPath -DestinationPath $InstallDir -Force
    Unblock-File -Path $ExePath
    Write-Host "Installed $ExePath"

    # Add to user PATH if missing. Takes effect in new terminals only.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $segments = if ($userPath) { $userPath -split ';' } else { @() }
    if ($segments -notcontains $InstallDir) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath + ';' + $InstallDir).TrimStart(';'), 'User')
        Write-Host "Added $InstallDir to user PATH. Open a new terminal for it to take effect."
    }

    # Claude Code integration. Preferred path: register the public repo as a
    # plugin marketplace and install the versioned `pathpoint` plugin --
    # skill plus the `p mcp-serve` MCP server -- so `claude plugin update`
    # (or re-running this installer) picks up new releases. Falls back to a
    # plain skills-dir copy when the claude CLI isn't on PATH or its plugin
    # commands fail (e.g. an older CLI). All of this is best-effort -- it
    # must never fail the binary install.
    $PluginInstalled = $false
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        # Explicit HTTPS git URL: the bare <owner>/<repo> shorthand clones
        # over SSH by default, which most users haven't set up for GitHub.
        $MarketplaceUrl = "https://github.com/$Repo.git"
        $PluginCmdsOk = $false

        function Write-PluginFallbackNote {
            Write-Host "Couldn't install the Claude Code plugin automatically; falling back to the plain skill."
            Write-Host "To retry the plugin by hand:"
            Write-Host "  claude plugin marketplace add $MarketplaceUrl"
            Write-Host "  claude plugin install pathpoint@outline-insurance --scope user"
        }
        function Write-PluginPathNote {
            # The plugin starts its MCP server as `p` from PATH, and the
            # PATH update this run makes only reaches new processes.
            if (($env:Path -split ';') -notcontains $InstallDir) {
                Write-Host "note: the plugin's MCP server runs 'p' from your PATH. Start Claude Code"
                Write-Host "      from a new terminal (so the PATH update above takes effect) or it"
                Write-Host "      won't be able to start the server."
            }
        }

        # A marketplace named 'outline-insurance' that points somewhere else
        # means the name has been claimed by another source -- every plugin
        # command below addresses the marketplace by name, so running them
        # would install from the impostor. Refuse the whole plugin path.
        $MpState = Get-PathpointMarketplaceState -ExpectedRepo $Repo
        if ($MpState -eq 'other') {
            Write-Warning "A plugin marketplace named 'outline-insurance' is already registered but points at a different source than $MarketplaceUrl."
            Write-Warning "Refusing to install or trust the plugin through it; using the plain skill instead."
            Write-Warning "If that marketplace isn't something you set up on purpose, replace it and re-run this installer:"
            Write-Warning "  claude plugin marketplace remove outline-insurance"
        } elseif ($PinnedVersion) {
            # A pinned install must be fully pinned. The plugin tracks the
            # repo's main branch (i.e. the latest release), so use the pinned
            # release's own SKILL.md below instead.
            Write-Host "P_VERSION is set; skipping the Claude Code plugin (it tracks the latest release)."
        } else {
            Write-Host "Claude Code detected; installing the Pathpoint plugin..."
            # `update` first: on re-runs it refreshes the already-registered
            # catalog (a stale catalog would pin the old plugin version); on
            # first runs it fails fast and `add` registers the marketplace.
            $mpOk = (Invoke-ClaudeQuiet @('plugin', 'marketplace', 'update', 'outline-insurance')) -or
                    (Invoke-ClaudeQuiet @('plugin', 'marketplace', 'add', $MarketplaceUrl))
            if ($mpOk) {
                $PluginCmdsOk = (Invoke-ClaudeQuiet @('plugin', 'install', 'pathpoint@outline-insurance', '--scope', 'user')) -or
                                (Invoke-ClaudeQuiet @('plugin', 'update', 'pathpoint@outline-insurance'))
            }
        }

        # Exit codes above aren't the full story: `plugin install` on an
        # already-installed-but-disabled plugin succeeds without enabling it
        # (the user's disable persists by design). Probe the actual state
        # and treat it per Get-PathpointPluginState's contract. Skipped
        # entirely when the marketplace name is claimed by another source --
        # a plugin from there must not suppress the plain skill.
        $PluginState = 'absent'
        if ($MpState -ne 'other') { $PluginState = Get-PathpointPluginState }
        switch ($PluginState) {
            'enabled' {
                $PluginInstalled = $true
                if ($PinnedVersion) {
                    Write-Host "note: the pathpoint Claude Code plugin is already installed and tracks the latest"
                    Write-Host "      release -- P_VERSION pins the binary only. To pin fully, remove it first:"
                    Write-Host "        claude plugin uninstall pathpoint@outline-insurance"
                } elseif ($PluginCmdsOk) {
                    Write-Host "Installed the Pathpoint plugin for Claude Code (pathpoint@outline-insurance)."
                    Write-PluginPathNote
                } else {
                    Write-Host "Plugin refresh failed; keeping the already-installed pathpoint plugin."
                }
            }
            'disabled' {
                Write-Host "note: the pathpoint Claude Code plugin is installed but disabled; leaving it"
                Write-Host "      alone and using the plain skill instead. To switch to the plugin:"
                Write-Host "        claude plugin enable pathpoint@outline-insurance"
                Write-Host "        del `"$SkillDir\SKILL.md`"   # then drop the plain copy so it isn't loaded twice"
            }
            'unknown' {
                if ($PluginCmdsOk) {
                    $PluginInstalled = $true
                    Write-Host "Installed the Pathpoint plugin for Claude Code (pathpoint@outline-insurance)."
                    Write-PluginPathNote
                } elseif (-not $PinnedVersion) {
                    Write-PluginFallbackNote
                }
            }
            default {
                # 'absent'
                if ($MpState -ne 'other' -and -not $PinnedVersion) {
                    Write-PluginFallbackNote
                }
            }
        }
    }

    if ($PluginInstalled) {
        # Move aside -- not delete, in case the user customized it -- the
        # plain skill copy earlier installers left behind. Alongside the
        # plugin it would load as a duplicate Pathpoint skill; as
        # SKILL.md.bak it loads as nothing. Only when the plugin is
        # CONFIRMED enabled: with the state unknown, a duplicate skill is
        # benign but removing what might be the only active copy is not.
        $LegacySkill = Join-Path $SkillDir 'SKILL.md'
        if ($PluginState -eq 'enabled' -and (Test-Path -LiteralPath $LegacySkill)) {
            # Never clobber an earlier backup -- it may hold user-customized
            # content while today's SKILL.md is just a pristine installer copy.
            $SkillBak = Join-Path $SkillDir 'SKILL.md.bak'
            if (Test-Path -LiteralPath $SkillBak) {
                $SkillBak = Join-Path $SkillDir "SKILL.md.bak.$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
            }
            try {
                Move-Item -LiteralPath $LegacySkill -Destination $SkillBak -ErrorAction Stop
                Write-Host "Moved legacy skill copy aside to $SkillBak (superseded by the plugin)."
            } catch {
                Write-Warning "Couldn't move the legacy skill copy at $LegacySkill aside; move or delete it by hand so the skill isn't loaded twice."
            }
        }
    } else {
        # Plain-skill fallback: install SKILL.md from the release into the
        # Claude Code skills dir.
        try {
            $skillTxt = (Invoke-WebRequest -Uri "$BaseUrl/SKILL.md" -UseBasicParsing -ErrorAction Stop).Content
            New-Item -ItemType Directory -Path $SkillDir -Force | Out-Null
            Set-Content -Path (Join-Path $SkillDir 'SKILL.md') -Value $skillTxt -Encoding UTF8
            Write-Host "Installed Pathpoint skill to $SkillDir\"
        } catch {
            # SKILL.md not in release — skip.
        }
    }

    # Configure Claude Desktop MCP server entry and stage the skill zip.
    # Write every layout we find: with both an MSIX and a classic install on the
    # same machine there is no way to tell which one the user launches, and a
    # spare entry in the config of an install they don't run is harmless.
    $ClaudeDirs = @(Get-ClaudeConfigDirs)
    $written = @()
    $failed  = @()
    if ($ClaudeDirs.Count -gt 0) {
        foreach ($dir in $ClaudeDirs) {
            # $ErrorActionPreference is 'Stop', so a locked or ACL'd config would
            # otherwise abort the whole installer here -- after p.exe is already
            # in place. Keep going and record it as a per-target failure.
            try {
                $path = Set-PathpointMcpServer $dir $ExePath
            } catch {
                Write-Warning "Could not write $([System.IO.Path]::Combine($dir, 'claude_desktop_config.json')): $_"
                $path = $null
            }
            if ($path) { $written += $path } else { $failed += $dir }
        }

        if ($written.Count -gt 0) {
            Write-Host "Configured Claude Desktop MCP server. Restart Claude Desktop to load."
            foreach ($path in $written) { Write-Host "  $path" }
            # A partial success is not a success: if the install the user
            # actually launches is one of the failures, nothing will work.
            foreach ($dir in $failed) {
                Write-Warning "Could not configure $([System.IO.Path]::Combine($dir, 'claude_desktop_config.json')) (see warning above)."
            }
            if ($failed.Count -gt 0) {
                Write-Warning "If pathpoint doesn't appear in Claude Desktop, that skipped file is why."
            }
        } else {
            # Every candidate was rejected. Say so -- p.exe is installed and
            # working, so without this the run looks like a success.
            Write-Warning "p is installed, but the Claude Desktop MCP server was NOT configured."
            Write-Warning "See the warnings above, then re-run this installer."
            Write-Warning "To wire it up by hand, edit whichever of these Claude Desktop reads:"
            foreach ($dir in $ClaudeDirs) { Write-Warning "  $([System.IO.Path]::Combine($dir, 'claude_desktop_config.json'))" }
            # These files usually already exist here -- a failed write often means
            # there was something in the way -- so be explicit that this is a
            # merge, not a replacement. Pasting a whole document into a populated
            # file is invalid JSON, and overwriting one loses the app's own
            # preferences alongside any other MCP servers.
            Write-Warning "Merge the ""pathpoint"" entry into that file's existing ""mcpServers"" object,"
            Write-Warning "or save this as the whole file if it doesn't exist yet:"
            Write-Host (Get-ManualConfigSnippet $ExePath)
        }

        # Claude Desktop skills don't have a local install path — they're
        # uploaded to Anthropic's servers via the in-app Settings UI. Stage
        # the zip somewhere obvious so the user only has to drag-and-drop.
        $Downloads = Join-Path $env:USERPROFILE 'Downloads'
        if (-not (Test-Path $Downloads)) { $Downloads = $env:USERPROFILE }
        $SkillZipDest = Join-Path $Downloads 'pathpoint-skill.zip'
        try {
            Invoke-WebRequest -Uri "$BaseUrl/pathpoint-skill.zip" -OutFile $SkillZipDest -UseBasicParsing -ErrorAction Stop
            Write-Host ""
            Write-Host "Pathpoint skill for Claude Desktop staged at:"
            Write-Host "  $SkillZipDest"
            Write-Host "To finish installing the skill in Claude Desktop:"
            Write-Host "  1. Open Claude Desktop"
            Write-Host "  2. Settings -> Capabilities -> Skills -> Create skill"
            Write-Host "  3. Upload the zip above"
        } catch {
            # skill zip not published in this release — skip silently
        }
    } else {
        Write-Host "Claude Desktop not detected; skipping MCP config and skill staging."
        Write-Host "If it is installed, launch it once and re-run this installer -- it creates"
        Write-Host "its config directory on first run."
        Write-Host ""
        # Deliberately not "use Settings -> Developer -> Edit Config": on MSIX
        # installs that button opens the non-virtualized %APPDATA% copy, which the
        # containerized app never reads.
        Write-Host "To wire it up by hand, save this as claude_desktop_config.json -- or if that"
        Write-Host "file already exists, merge the ""pathpoint"" entry into its ""mcpServers"" object:"
        Write-Host (Get-ManualConfigSnippet $ExePath)
        Write-Host "MSIX installs read %LOCALAPPDATA%\Packages\Claude_<hash>\LocalCache\Roaming\Claude\;"
        Write-Host "classic installs read %APPDATA%\Claude\."
    }

    Write-Host ""
    # Deliberately still exit 0 when only the MCP config failed: p.exe itself is
    # installed and on PATH, and `p update` surfaces this script's exit code as an
    # update failure. Don't report a working binary as a failed install -- but
    # don't claim a bare "Done" either. A partial write counts as incomplete: the
    # install the user actually launches may be one of the failures. The bare
    # "Done" is reserved for the case where every target was written.
    if ($ClaudeDirs.Count -eq 0) {
        Write-Host "Done installing p. Claude Desktop wasn't found, so its MCP server and skill"
        Write-Host "were not set up (see above); nothing else is outstanding."
        Write-Host "Open a new terminal and run: p login"
    } elseif ($failed.Count -eq 0) {
        Write-Host "Done. Open a new terminal and run: p login"
    } elseif ($written.Count -gt 0) {
        Write-Host "Done installing p, but $($failed.Count) of $($ClaudeDirs.Count) Claude Desktop configs could not be written (see above)."
        Write-Host "Open a new terminal and run: p login"
    } else {
        Write-Host "Done installing p, but the Claude Desktop MCP server was NOT configured (see above)."
        Write-Host "Open a new terminal and run: p login"
    }
    Write-Host "(On first run, Windows SmartScreen may prompt once -- click 'More info' then 'Run anyway'.)"
}
finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
