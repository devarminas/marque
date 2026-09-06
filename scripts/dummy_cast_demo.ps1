<#
.SYNOPSIS
    M6e practice dummies: one client selects both, heals the friendly dummy,
    fireballs the hostile dummy. Exits 0 only when DEMO done and GAMELOG shows
    cast_effect for heal and fireball on the seeded NPC ids.
#>
[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-dummy-cast"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-dummy-cast-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
$clientOut = Join-Path $OutDir "client.stdout.log"
$clientErr = Join-Path $OutDir "client.stderr.log"
$evidenceMarker = Join-Path $OutDir ".marque-evidence"

$server = $null
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure([string] $message) { $failures.Add($message) }

function Show-File([string] $label, [string] $path) {
    if (-not (Test-Path $path)) { return }
    $content = Get-Content -Path $path -Raw
    if ([string]::IsNullOrWhiteSpace($content)) { return }
    Write-Host ""
    Write-Host "--- $label ---"
    Write-Host $content.TrimEnd()
}

try {
    if (Test-Path $OutDir) {
        if (-not (Test-Path $evidenceMarker)) {
            throw "Refusing to empty $OutDir without .marque-evidence marker"
        }
        Remove-Item -Recurse -Force $OutDir
    }
    New-Item -ItemType Directory -Path $OutDir | Out-Null
    Set-Content -Path $evidenceMarker -Value "marque-dummy-cast"

    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    $server = Start-Process -FilePath $binary -ArgumentList @("-addr", "127.0.0.1:0") `
        -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr `
        -NoNewWindow -PassThru

    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    $wsUrl = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $serverOut) {
            foreach ($line in Get-Content $serverOut -ErrorAction SilentlyContinue) {
                if ($line -match 'GAMELOG .*\"ev\":\"server_started\"') {
                    $json = ($line -replace '^GAMELOG ', '') | ConvertFrom-Json
                    $wsUrl = "ws://$($json.addr)/ws"
                    break
                }
            }
        }
        if ($wsUrl) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $wsUrl) { throw "server_started not seen within ${ReadyTimeoutSeconds}s" }
    Write-Host "SERVER $wsUrl"

    $client = Start-Process -FilePath $Godot -ArgumentList @(
        "--path", $clientDir,
        "--",
        "--server", $wsUrl,
        "--dummy-cast"
    ) -RedirectStandardOutput $clientOut -RedirectStandardError $clientErr -PassThru

    $client.WaitForExit($ClientTimeoutSeconds * 1000) | Out-Null
    if (-not $client.HasExited) {
        Stop-Process -Id $client.Id -Force
        Add-Failure "client timed out after ${ClientTimeoutSeconds}s"
    } else {
        try { $client.Refresh() } catch { }
        $code = $client.ExitCode
        if ($null -eq $code) {
            # Process object sometimes lacks ExitCode after WaitForExit on Godot.
        } elseif ([int]$code -ne 0) {
            Add-Failure "client exit $code"
        }
    }

    $done = $false
    $healOk = $false
    $fireOk = $false
    $healFx = $false
    $fireFx = $false
    $npcCount = 0
    if (Test-Path $clientOut) {
        foreach ($line in Get-Content $clientOut) {
            if ($line -match '^DEMO npc ') { $npcCount++ }
            if ($line -match '^DEMO healok ') { $healOk = $true }
            if ($line -match '^DEMO fireballok ') { $fireOk = $true }
            if ($line -match '^DEMO castfx \d+ heal\s*$') { $healFx = $true }
            if ($line -match '^DEMO castfx \d+ fireball\s*$') { $fireFx = $true }
            if ($line -match '^DEMO done\s*$') { $done = $true }
            if ($line -match '^DEMO FAIL ') { Add-Failure $line.Trim() }
        }
    }
    if ($npcCount -lt 2) { Add-Failure "DEMO npc lines=$npcCount, want >= 2" }
    if (-not $healOk) { Add-Failure "missing DEMO healok" }
    if (-not $fireOk) { Add-Failure "missing DEMO fireballok" }
    if (-not $healFx) { Add-Failure "missing DEMO castfx heal" }
    if (-not $fireFx) { Add-Failure "missing DEMO castfx fireball" }
    if (-not $done) { Add-Failure "missing DEMO done" }

    $healEffect = 0
    $fireEffect = 0
    $spawned = 0
    if (Test-Path $serverOut) {
        foreach ($line in Get-Content $serverOut) {
            if (-not $line.StartsWith("GAMELOG ")) { continue }
            $ev = ($line.Substring(8) | ConvertFrom-Json)
            if ($ev.ev -eq "npc_spawned") { $spawned++ }
            if ($ev.ev -eq "cast_effect" -and $ev.ability -eq "heal") { $healEffect++ }
            if ($ev.ev -eq "cast_effect" -and $ev.ability -eq "fireball") { $fireEffect++ }
        }
    }
    if ($spawned -lt 2) { Add-Failure "npc_spawned=$spawned, want >= 2" }
    if ($healEffect -lt 1) { Add-Failure "cast_effect heal=$healEffect, want >= 1" }
    if ($fireEffect -lt 1) { Add-Failure "cast_effect fireball=$fireEffect, want >= 1" }

    Show-File "client stdout" $clientOut
    Show-File "client stderr" $clientErr
    if ($failures.Count -gt 0) {
        Write-Host "FAILURES:"
        $failures | ForEach-Object { Write-Host " - $_" }
        exit 1
    }
    Write-Host "DUMMY CAST DEMO OK"
    exit 0
}
finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
