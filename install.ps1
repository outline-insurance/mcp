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

$Repo       = if ($env:P_REPO)        { $env:P_REPO }        else { 'outline-insurance/mcp' }
$Version    = if ($env:P_VERSION)     { $env:P_VERSION }     else { 'latest' }
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

    # Install Claude Code skill if the release ships SKILL.md.
    try {
        $skillTxt = (Invoke-WebRequest -Uri "$BaseUrl/SKILL.md" -UseBasicParsing -ErrorAction Stop).Content
        New-Item -ItemType Directory -Path $SkillDir -Force | Out-Null
        Set-Content -Path (Join-Path $SkillDir 'SKILL.md') -Value $skillTxt -Encoding UTF8
        Write-Host "Installed Pathpoint skill to $SkillDir\"
    } catch {
        # SKILL.md not in release — skip.
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
