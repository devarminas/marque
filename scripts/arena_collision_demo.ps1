[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-arena-collision"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-arena-collision-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
$clientOut = Join-Path $OutDir "client.stdout.log"
$clientErr = Join-Path $OutDir "client.stderr.log"
$shotsPrefix = Join-Path $OutDir "arena"
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
    Set-Content -Path $evidenceMarker -Value "marque-arena-collision"

    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    $server = Start-Process -FilePath $binary -ArgumentList @(
        "-addr", "127.0.0.1:0",
        "-map", "arena_ring_of_trials"
    ) -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr `
        -NoNewWindow -PassThru

    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    $wsUrl = $null
    $startedMap = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $serverOut) {
            foreach ($line in Get-Content $serverOut -ErrorAction SilentlyContinue) {
                if ($line -match 'GAMELOG .*\"ev\":\"server_started\"') {
                    $json = ($line -replace '^GAMELOG ', '') | ConvertFrom-Json
                    $wsUrl = "ws://$($json.addr)/ws"
                    $startedMap = [string]$json.map
                    break
                }
            }
        }
        if ($wsUrl) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $wsUrl) { throw "server_started not seen within ${ReadyTimeoutSeconds}s" }
    if ($startedMap -ne "arena_ring_of_trials") {
        throw "server map=$startedMap, want arena_ring_of_trials"
    }
    Write-Host "SERVER $wsUrl map=$startedMap"

    $env:MARQUE_MAP = "arena"
    $client = Start-Process -FilePath $Godot -ArgumentList @(
        "--path", $clientDir,
        "--position", "40,60",
        "--",
        "--server", $wsUrl,
        "--map", "arena",
        "--arena-collision-shots", $shotsPrefix
    ) -RedirectStandardOutput $clientOut -RedirectStandardError $clientErr -PassThru

    $client.WaitForExit($ClientTimeoutSeconds * 1000) | Out-Null
    if (-not $client.HasExited) {
        Stop-Process -Id $client.Id -Force
        Add-Failure "client timed out after ${ClientTimeoutSeconds}s"
    } else {
        try { $client.Refresh() } catch { }
        $code = $client.ExitCode
        if ($null -ne $code -and [int]$code -ne 0) {
            Add-Failure "client exit $code"
        }
    }

    $done = $false
    $wallBlocked = $false
    $rampRise = $null
    $jumpPeak = $null
    $jumpLand = $null
    $posLines = 0
    $shots = 0
    if (Test-Path $clientOut) {
        foreach ($line in Get-Content $clientOut) {
            if ($line -match '^DEMO pos ') { $posLines++ }
            if ($line -match '^DEMO shot ') { $shots++ }
            if ($line -match '^DEMO wall_blocked ') { $wallBlocked = $true }
            if ($line -match '^DEMO ramp_rise ([0-9.]+)') {
                $rampRise = [double]$Matches[1]
            }
            if ($line -match '^DEMO jump_peak_y ([0-9.]+)') {
                $jumpPeak = [double]$Matches[1]
            }
            if ($line -match '^DEMO jump_land_y ([0-9.]+)') {
                $jumpLand = [double]$Matches[1]
            }
            if ($line -match '^DEMO done\s*$') { $done = $true }
            if ($line -match '^DEMO FAIL ') { Add-Failure $line.Trim() }
        }
    }
    if (-not $done) { Add-Failure "missing DEMO done" }
    if (-not $wallBlocked) { Add-Failure "missing DEMO wall_blocked" }
    if ($null -eq $rampRise -or $rampRise -lt 0.35) {
        Add-Failure "DEMO ramp_rise=$rampRise, want >= 0.35"
    }
    if ($null -eq $jumpPeak -or $null -eq $jumpLand) {
        Add-Failure "missing DEMO jump_peak_y / jump_land_y"
    } elseif ($jumpPeak -lt ($jumpLand + 0.2)) {
        Add-Failure "jump peak $jumpPeak not above land $jumpLand by 0.2"
    }
    if ($posLines -lt 5) { Add-Failure "DEMO pos lines=$posLines, want >= 5" }
    if ($shots -lt 5) { Add-Failure "DEMO shot lines=$shots, want >= 5" }

    for ($i = 1; $i -le 5; $i++) {
        $shotPath = "${shotsPrefix}_${i}.png"
        if (-not (Test-Path $shotPath)) {
            Add-Failure "missing shot $shotPath"
            continue
        }
        $len = (Get-Item $shotPath).Length
        if ($len -lt 4096) {
            Add-Failure "shot $shotPath is ${len}B, want >4KB"
        }
    }

    $moveEvents = 0
    $jumpMoves = 0
    $pathEvents = 0
    if (Test-Path $serverOut) {
        foreach ($line in Get-Content $serverOut) {
            if ($line -match 'GAMELOG ') {
                $json = ($line -replace '^GAMELOG ', '') | ConvertFrom-Json
                if ($json.ev -eq "move") {
                    $moveEvents++
                    if ($json.jump -eq $true) { $jumpMoves++ }
                }
                if ($json.ev -eq "path_assigned") {
                    $hasPlayer = $json.PSObject.Properties.Name -contains "player"
                    if ($hasPlayer -and $null -ne $json.player) {
                        $pathEvents++
                    }
                }
            }
        }
    }
    if ($moveEvents -lt 1) { Add-Failure "GAMELOG move events=$moveEvents, want >= 1" }
    if ($jumpMoves -lt 1) { Add-Failure "GAMELOG move jump=true events=$jumpMoves, want >= 1" }
    if ($pathEvents -gt 0) {
        Add-Failure "GAMELOG path_assigned=$pathEvents, want 0 for player wish steer"
    }

    if ($failures.Count -gt 0) {
        Show-File "client stdout" $clientOut
        Show-File "client stderr" $clientErr
        Show-File "server stdout" $serverOut
        foreach ($f in $failures) { Write-Host "FAIL: $f" }
        exit 1
    }
    Write-Host "ARENA COLLISION DEMO OK"
    exit 0
} finally {
    if ($null -ne $server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $work) {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
}
