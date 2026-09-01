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
    # Not captured via the PowerShell pipeline on purpose: godot.exe is a
    # GUI-subsystem binary, so `$v = & godot --version` reads back empty even
    # though the same command prints fine on an interactive console. Routing
    # through cmd.exe is the one capture that works; the run scripts are immune
    # because Start-Process -RedirectStandardOutput hands the process a real
    # stdout handle.
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
    "scripts\two_client_demo.ps1"
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

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "DOCTOR OK"
    exit 0
}
Write-Host "DOCTOR FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1
