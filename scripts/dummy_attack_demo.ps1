[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-dummy-attack"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 90,
    [ValidateRange(0, 100)] [int] $WhiteMissPct = 0,
    [ValidateRange(0, 100)] [int] $ForceCritPct = 0,
    [ValidateRange(0, 100)] [int] $ForceCritAfterWhites = 0,
    [switch] $ObserveFctLifetime,
    [switch] $ReviewMovie,
    [switch] $FctOff,
    [switch] $YawSamples
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
$whiteFctShot = Join-Path $OutDir "fct-white.png"
$critFctShot = Join-Path $OutDir "fct-crit.png"
$reviewPrefix = Join-Path $OutDir "fct-review"
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

    $serverArgs = @("-addr", "127.0.0.1:0", "-admin", "-white-miss-pct", "$WhiteMissPct")
    if ($ForceCritPct -gt 0) {
        $serverArgs += @("-force-crit-pct", "$ForceCritPct", "-force-crit-after-whites", "$ForceCritAfterWhites")
    }
    $server = Start-Process -FilePath $binary -ArgumentList $serverArgs `
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

    $clientArgs = @("--path", $clientDir, "--", "--server", $wsUrl, "--dummy-attack")
    if ($WhiteMissPct -eq 100) {
        $clientArgs += @("--expect-white-miss", "--miss-shot", (Join-Path $OutDir "miss.png"))
    }
    if ($ForceCritPct -eq 100) {
        $clientArgs += @("--fct-white-shot", $whiteFctShot, "--fct-crit-shot", $critFctShot)
    }
    if ($ReviewMovie) {
        if ($WhiteMissPct -ne 100 -and $ForceCritPct -ne 100) {
            throw "-ReviewMovie needs -WhiteMissPct 100 or -ForceCritPct 100"
        }
        $clientArgs += @("--fct-review-prefix", $reviewPrefix)
    }
    if ($FctOff) { $clientArgs += "--fct-off" }
    if ($YawSamples) { $clientArgs += "--yaw-samples" }
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
    $yawBefore = $false
    $yawMid = $false
    $yawAfter = $false
    $refuseOk = $false
    $attackOk = $false
    $missOk = $false
    $missHPOk = $false
    $reviewFrameCount = 0
    $missFctOk = $false
    $npcCount = 0
    $critScales = @()
    $whiteScales = @()
    $fctLifetimePresent = 0
    $fctLifetimeGone = 0
    if (Test-Path $clientOut) {
        foreach ($line in Get-Content $clientOut) {
            if ($line -match '^DEMO npc ') { $npcCount++ }
            if ($line -match '^DEMO refuse ') { $refuseOk = $true }
            if ($line -match '^DEMO attackok ') { $attackOk = $true }
            if ($line -match '^DEMO yaw attack before=.* mid=') { $yawBefore = $true; $yawMid = $true }
            if ($line -match '^DEMO yaw attack after=') { $yawAfter = $true }
            if ($line -match '^DEMO miss \d+ amount=0 crit=false hp=') { $missOk = $true }
            if ($line -match '^DEMO misshp \d+ unchanged=') { $missHPOk = $true }
            if ($line -match '^DEMO fctframes (\d+)$') { $reviewFrameCount += [int]$Matches[1] }
            if ($line -match '^DEMO fct miss text=Miss scale=\d+ color=999999ff$') { $missFctOk = $true }
            if ($line -match '^DEMO fct crit=\d+ scale=(\d+) text=\d+!$') { $critScales += [int]$Matches[1] }
            if ($line -match '^DEMO fct white=\d+ scale=(\d+) text=\d+$') { $whiteScales += [int]$Matches[1] }
            if ($line -match '^DEMO fct lifetime present ') { $fctLifetimePresent++ }
            if ($line -match '^DEMO fct lifetime gone ') { $fctLifetimeGone++ }
            if ($line -match '^DEMO done\s*$') { $done = $true }
            if ($line -match '^DEMO FAIL ') { Add-Failure $line.Trim() }
        }
    }
    if ($npcCount -lt 2) { Add-Failure "DEMO npc lines=$npcCount, want >= 2" }
    if (-not $refuseOk) { Add-Failure "missing DEMO refuse" }
    if ($WhiteMissPct -eq 100) {
        if (-not $missOk -or -not $missHPOk -or -not $missFctOk) { Add-Failure "missing DEMO miss, misshp, or grey Miss float" }
        if ($ReviewMovie -and $reviewFrameCount -ne 150) { Add-Failure "review frames=$reviewFrameCount, want 150" }
    } elseif ($ForceCritPct -eq 100) {
        if ($whiteScales.Count -lt 1) { Add-Failure "no DEMO fct white scale with ForceCritPct=100" }
        if ($critScales.Count -lt 1) { Add-Failure "no DEMO fct crit scale with ForceCritPct=100" }
        if ($whiteScales.Count -gt 0 -and $critScales.Count -gt 0 -and $critScales[0] -le $whiteScales[0]) {
            Add-Failure "observed crit scale $($critScales[0]) must exceed observed white scale $($whiteScales[0])"
        }
        if (-not (Test-Path $whiteFctShot)) { Add-Failure "missing game-authored white float screenshot" }
        if (-not (Test-Path $critFctShot)) { Add-Failure "missing game-authored crit float screenshot" }
        if ($ReviewMovie -and $reviewFrameCount -ne 150) { Add-Failure "review frames=$reviewFrameCount, want 150" }
    } elseif (-not $attackOk) { Add-Failure "missing DEMO attackok" }
    if (-not $done) { Add-Failure "missing DEMO done" }
    if ($YawSamples -and (-not $yawBefore -or -not $yawMid -or -not $yawAfter)) { Add-Failure "missing before/mid/after yaw samples" }
    if ($ReviewMovie -and (Get-ChildItem -Path "$reviewPrefix-*.png" -ErrorAction SilentlyContinue).Count -ne 150) {
        Add-Failure "game-authored review frame files missing"
    }
    if ($ObserveFctLifetime -and ($fctLifetimePresent -lt 1 -or $fctLifetimeGone -lt 1)) {
        Add-Failure "FCT lifetime present=$fctLifetimePresent gone=$fctLifetimeGone, want both"
    }

    $attacks = 0
    $hits = 0
    $spawned = 0
    $missHits = 0
    $landedHits = 0
    $critHits = 0
    $whiteHits = 0
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
                $isPlayerHit = $null -ne $ev.PSObject.Properties["player"]
                if ($isPlayerHit -and $ev.crit -eq $true -and $ev.miss -eq $false) { $critHits++ }
                if ($isPlayerHit -and $ev.crit -eq $false -and $ev.miss -eq $false -and $ev.applied -gt 0) { $whiteHits++ }
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
    if ($ForceCritPct -eq 100 -and $critHits -lt 1) { Add-Failure "crit hits=$critHits, want >= 1 with force-crit-pct=100" }
    if ($ForceCritPct -eq 100 -and $whiteHits -lt 1) { Add-Failure "white hits=$whiteHits, want >= 1 before the forced crit" }
    if ($WhiteMissPct -ne 100 -and $ForceCritPct -ne 100 -and $landedHits -lt 1) { Add-Failure "landed hits=$landedHits, want >= 1" }

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
