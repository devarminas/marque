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
