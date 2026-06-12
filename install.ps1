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
$ClaudeCfg  = "$env:APPDATA\Claude\claude_desktop_config.json"

$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }

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
    if (Test-Path (Split-Path $ClaudeCfg -Parent)) {
        # Build a hashtable from the existing config (if any). Avoids
        # ConvertFrom-Json -AsHashtable, which doesn't exist on Windows
        # PowerShell 5.1 — the runtime that ships with stock Windows and
        # the most likely host for this `irm | iex` one-liner.
        function ConvertTo-PSHashtable($obj) {
            if ($null -eq $obj) { return @{} }
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

        $cfg = if (Test-Path $ClaudeCfg) {
            ConvertTo-PSHashtable (Get-Content $ClaudeCfg -Raw | ConvertFrom-Json)
        } else { [ordered]@{} }

        if (-not $cfg.Contains('mcpServers')) { $cfg['mcpServers'] = [ordered]@{} }
        $cfg['mcpServers']['pathpoint'] = [ordered]@{
            command = (Join-Path $InstallDir 'p.exe')
            args    = @('mcp-serve')
        }
        $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $ClaudeCfg -Encoding UTF8
        Write-Host "Configured Claude Desktop MCP server. Restart Claude Desktop to load."

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
    }

    Write-Host ""
    Write-Host "Done. Open a new terminal and run: p login"
    Write-Host "(On first run, Windows SmartScreen may prompt once -- click 'More info' then 'Run anyway'.)"
}
finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
