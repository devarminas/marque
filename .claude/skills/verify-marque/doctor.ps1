<#
.SYNOPSIS
    Read-only preflight for the verify-marque skill. Answers "is this checkout
    worth driving?" without starting, building, or writing anything.

.DESCRIPTION
    Prints DOCTOR OK and exits 0 when the toolchain and repo layout are what the
    skill's recipes assume. Prints DOCTOR FAILED with one line per problem and
    exits 1 otherwise. A missing client/.godot/ cache is a warning, not a
    failure, because run.ps1 heals it; the warning names the exact command.
#>
[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# .claude/skills/verify-marque -> skills -> .claude -> repo root.
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$failures = New-Object System.Collections.Generic.List[string]

try {
    $goVersion = (& go version) 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($goVersion)) {
        $failures.Add("go is not answering on PATH")
    } else {
        Write-Host "==> $goVersion"
    }
} catch {
    $failures.Add("go is not on PATH: $($_.Exception.Message)")
}

try {
    # Captured through a pipeline on purpose, which is the half of this that
    # matters. Measured on this machine and recorded in NOTES.md, "Godot
    # authoring traps": `$v = godot --version` reads back empty, and so do the
    # `@(...)`, `(...)` and `$(...)` forms, while `| Out-String`,
    # `| ForEach-Object` and `| Select-Object -First 1` all capture
    # `4.7.2.stable.official...`. A preflight written as
    # `if (-not ($v = godot --version)) { fail }` therefore reports Godot
    # missing on a machine where it is installed and on PATH.
    #
    # The `cmd /c` wrapper is here for `2>nul` — keeping Godot's stderr off
    # this script's error stream — not for the capture. The
    # `| Select-Object -First 1` after it is what captures, and it works
    # without the wrapper.
    #
    # No mechanism is claimed. NOTES.md records that table as observed
    # behaviour and marks the GUI-subsystem explanation explicitly unverified.
    # The run scripts are immune either way, because Start-Process
    # -RedirectStandardOutput hands the process a real file handle rather than
    # a pipeline.
    $godotVersion = (cmd /c "`"$Godot`" --version 2>nul") | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($godotVersion)) {
        $failures.Add("'$Godot' is not answering (set `$env:GODOT or put godot on PATH)")
    } elseif ($godotVersion -notmatch "^4\.7\.") {
        $failures.Add("'$Godot' reports '$godotVersion'; this project is pinned to Godot 4.7")
    } else {
        Write-Host "==> godot $godotVersion"
    }
} catch {
    $failures.Add("'$Godot' is not runnable: $($_.Exception.Message)")
}

foreach ($relative in @(
    "server\cmd\marqued\main.go",
    "server\go.mod",
    "client\project.godot",
    "client\scripts\main.gd",
    "client\tests\run_tests.gd",
    "scripts\interop_test.ps1",
    "scripts\two_client_demo.ps1",
    "scripts\contested_pickup_demo.ps1",
    "scripts\equip_demo.ps1"
)) {
    if (-not (Test-Path (Join-Path $repo $relative))) {
        $failures.Add("missing $relative; this is not the checkout the skill was written against")
    }
}

if (-not (Test-Path (Join-Path $repo "client\.godot"))) {
    Write-Host "==> WARNING: client\.godot is absent (fresh checkout)."
    Write-Host "    Headless Godot will fail to parse global class_name scripts until you run:"
    Write-Host "        godot --headless --path client --editor --quit"
    Write-Host "    run.ps1 does this itself; standalone godot commands will not."
}

$allowlistPath = Join-Path $PSScriptRoot "demo-allowlist.txt"
if (-not (Test-Path $allowlistPath)) {
    $failures.Add("missing .claude/skills/verify-marque/demo-allowlist.txt")
} else {
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($raw in Get-Content -LiteralPath $allowlistPath) {
        $line = $raw
        $hash = $line.IndexOf('#')
        if ($hash -ge 0) { $line = $line.Substring(0, $hash) }
        $line = $line.Trim()
        if ($line.Length -eq 0) { continue }
        [void]$allowed.Add($line.Replace('\', '/'))
    }

    function Get-RepoRelativeForwardSlash {
        param([string] $FullPath)
        $full = [System.IO.Path]::GetFullPath($FullPath)
        $root = [System.IO.Path]::GetFullPath($repo)
        if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $full.Replace('\', '/')
        }
        $rel = $full.Substring($root.Length).TrimStart('\', '/')
        return $rel.Replace('\', '/')
    }

    foreach ($dirRel in @("scripts", "client\scripts")) {
        $dir = Join-Path $repo $dirRel
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        # Match *_demo.ps1 / *_demo.gd only — not helpers like marque-demo-lib.ps1
        # or demo_npc_capture.gd (those are not windowed demos).
        $filter = if ($dirRel -eq "scripts") { "*_demo.ps1" } else { "*_demo.gd" }
        Get-ChildItem -LiteralPath $dir -File -Filter $filter | ForEach-Object {
            $rel = Get-RepoRelativeForwardSlash $_.FullName
            if (-not $allowed.Contains($rel)) {
                $failures.Add("unlisted windowed demo: $rel (add to demo-allowlist.txt or delete it)")
            }
        }
    }

    $mainGd = Join-Path $repo "client\scripts\main.gd"
    if (Test-Path -LiteralPath $mainGd) {
        $mainText = Get-Content -LiteralPath $mainGd -Raw
        $shotMatches = [regex]::Matches($mainText, '"--(?:[a-z0-9]+-)*shots"')
        $seenShots = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($m in $shotMatches) {
            $flag = $m.Value.Trim('"')
            if (-not $seenShots.Add($flag)) { continue }
            if (-not $allowed.Contains($flag)) {
                $failures.Add("unlisted --*-shots flag in main.gd: $flag (add to demo-allowlist.txt or remove it)")
            }
        }
    }
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "DOCTOR OK"
    exit 0
}
Write-Host "DOCTOR FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1
