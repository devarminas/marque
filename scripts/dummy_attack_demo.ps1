[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-dummy-attack"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 90,
    [ValidateRange(0, 100)] [int] $WhiteMissPct = 0,
    [switch] $ReviewMovie,
    [switch] $FctOff
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-dummy-attack-" + [guid]::NewGuid().ToString("n"))
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
    Set-Content -Path $evidenceMarker -Value "marque-dummy-attack"

    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    $server = Start-Process -FilePath $binary -ArgumentList @(
        "-addr", "127.0.0.1:0",
        "-admin",
        "-white-miss-pct", "$WhiteMissPct"
    ) -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr `
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

    $clientArgs = @("--path", $clientDir, "--", "--server", $wsUrl, "--dummy-attack")
    if ($WhiteMissPct -eq 100) {
        $clientArgs += @("--expect-white-miss", "--miss-shot", (Join-Path $OutDir "miss.png"))
        if ($ReviewMovie) { $clientArgs += "--miss-review" }
    }
    if ($ReviewMovie -and $WhiteMissPct -ne 100) { throw "-ReviewMovie needs -WhiteMissPct 100" }
    if ($FctOff) { $clientArgs += "--fct-off" }
    $client = Start-Process -FilePath $Godot -ArgumentList $clientArgs `
        -RedirectStandardOutput $clientOut -RedirectStandardError $clientErr -PassThru

    $client.WaitForExit($ClientTimeoutSeconds * 1000) | Out-Null
    if (-not $client.HasExited) {
        Stop-Process -Id $client.Id -Force
        Add-Failure "client timed out after ${ClientTimeoutSeconds}s"
    } else {
        try { $client.Refresh() } catch { }
        $code = $client.ExitCode
        if ($null -eq $code) {
        } elseif ([int]$code -ne 0) {
            Add-Failure "client exit $code"
        }
    }

    $done = $false
    $refuseOk = $false
    $attackOk = $false
    $missOk = $false
    $missHPOk = $false
    $missFramesOk = $false
    $npcCount = 0
    if (Test-Path $clientOut) {
        foreach ($line in Get-Content $clientOut) {
            if ($line -match '^DEMO npc ') { $npcCount++ }
            if ($line -match '^DEMO refuse ') { $refuseOk = $true }
            if ($line -match '^DEMO attackok ') { $attackOk = $true }
            if ($line -match '^DEMO miss \d+ amount=0 crit=false hp=') { $missOk = $true }
            if ($line -match '^DEMO misshp \d+ unchanged=') { $missHPOk = $true }
            if ($line -match '^DEMO missframes 30$') { $missFramesOk = $true }
            if ($line -match '^DEMO done\s*$') { $done = $true }
            if ($line -match '^DEMO FAIL ') { Add-Failure $line.Trim() }
        }
    }
    if ($npcCount -lt 2) { Add-Failure "DEMO npc lines=$npcCount, want >= 2" }
    if (-not $refuseOk) { Add-Failure "missing DEMO refuse" }
    if ($WhiteMissPct -eq 100) {
        if (-not $missOk -or -not $missHPOk) { Add-Failure "missing DEMO miss or misshp" }
        if ($ReviewMovie -and -not $missFramesOk) { Add-Failure "missing DEMO missframes 30" }
    } elseif (-not $attackOk) { Add-Failure "missing DEMO attackok" }
    if (-not $done) { Add-Failure "missing DEMO done" }

    $attacks = 0
    $hits = 0
    $spawned = 0
    $missHits = 0
    $landedHits = 0
    if (Test-Path $serverOut) {
        foreach ($line in Get-Content $serverOut) {
            if (-not $line.StartsWith("GAMELOG ")) { continue }
            $ev = ($line.Substring(8) | ConvertFrom-Json)
            if ($ev.ev -eq "npc_spawned") { $spawned++ }
            if ($ev.ev -eq "attack") { $attacks++ }
            if ($ev.ev -eq "attack_hit") {
                $hits++
                if ($ev.miss -eq $true -and $ev.crit -eq $false -and $ev.applied -eq 0 -and $ev.damage -eq 0) { $missHits++ }
                if ($ev.miss -eq $false -and $ev.applied -gt 0) { $landedHits++ }
            }
            if ($ev.ev -eq "attack_rejected") {
                Add-Failure "unexpected attack_rejected on the happy path: $line"
            }
        }
    }
    if ($spawned -lt 2) { Add-Failure "npc_spawned=$spawned, want >= 2" }
    if ($attacks -lt 1) { Add-Failure "attack=$attacks, want >= 1" }
    if ($hits -lt 1) { Add-Failure "attack_hit=$hits, want >= 1" }
    if ($WhiteMissPct -eq 100 -and $missHits -ne $hits) { Add-Failure "honest misses=$missHits, hits=$hits" }
    if ($WhiteMissPct -ne 100 -and $landedHits -lt 1) { Add-Failure "landed hits=$landedHits, want >= 1" }

    Show-File "client stdout" $clientOut
    Show-File "client stderr" $clientErr
    if ($failures.Count -gt 0) {
        Write-Host "FAILURES:"
        $failures | ForEach-Object { Write-Host " - $_" }
        exit 1
    }
    Write-Host "DUMMY ATTACK DEMO OK"
    exit 0
}
finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
