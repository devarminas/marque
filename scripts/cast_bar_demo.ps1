[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-cast-bar"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 90,
    [switch] $CooldownProof,
    [switch] $Sweep,
    [switch] $RefusalDemo,
    [switch] $OutOfMana,
    [switch] $YawSamples
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "marque-demo-lib.ps1")

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-cast-bar-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
$clientOut = Join-Path $OutDir "client.stdout.log"
$clientErr = Join-Path $OutDir "client.stderr.log"
$prefix = Join-Path $OutDir "c"
$server = $null
$failures = New-MarqueDemoFailures

function Read-ClientReport([string] $path) {
    $report = @{
        Joined = -1
        Failures = New-Object System.Collections.Generic.List[string]
        Done = $false
        YawBeforeMid = $false
        YawAfter = $false
        CastOk = $false
        CastCancel = $false
        CastBarVisible = $false
        CastBarHidden = $false
        CooldownFirstReady = $false
        CooldownFireballRefused = $false
        CooldownHealRefused = $false
        CooldownWelcome = $false
        CooldownCancelled = $false
        CooldownAfterReady = $false
        CooldownResolves = New-Object System.Collections.Generic.List[string]
        CooldownReason = $false
        OutOfRangeReason = $false
        InsufficientManaReason = $false
        ErrorTintRange = $false
        ErrorTintMana = $false
        ErrorText = $false
        ErrorCleared = $false
        NoDebit = $false
        ManaBefore = -1
        ManaAfter = -1
        SweepStates = New-Object System.Collections.Generic.List[string]
        HotbarPresses = New-Object System.Collections.Generic.List[string]
    }
    if (-not (Test-Path $path)) { return $report }
    foreach ($line in Get-Content -Path $path) {
        switch -Regex ($line) {
            '^DEMO joined (\d+)\s*$' { $report.Joined = [int]$Matches[1] }
            '^DEMO FAIL (.+)$' { $report.Failures.Add($Matches[1].Trim()) }
            '^DEMO done\s*$' { $report.Done = $true }
            '^DEMO yaw cast before=.* mid=' { $report.YawBeforeMid = $true }
            '^DEMO yaw cast after=' { $report.YawAfter = $true }
            '^DEMO castok ' { $report.CastOk = $true }
            '^DEMO castcancel ' { $report.CastCancel = $true }
            '^DEMO castbar .+ visible=1\s*$' { $report.CastBarVisible = $true }
            '^DEMO castbar .+ visible=0\s*$' { $report.CastBarHidden = $true }
            '^DEMO cooldown first_ready fireball\s*$' { $report.CooldownFirstReady = $true }
            '^DEMO cooldown_refuse fireball ' { $report.CooldownFireballRefused = $true }
            '^DEMO castrefusal reason=cooldown ' { $report.CooldownReason = $true }
            '^DEMO castrefusal reason=out_of_range ' { $report.OutOfRangeReason = $true }
            '^DEMO castrefusal reason=insufficient_mana ' { $report.InsufficientManaReason = $true }
            '^DEMO errortint out_of_range ' { $report.ErrorTintRange = $true }
            '^DEMO errortint insufficient_mana ' { $report.ErrorTintMana = $true }
            '^DEMO errortext (Not ready yet|Out of range|Not enough mana)\s*$' { $report.ErrorText = $true }
            '^DEMO errorcleared\s*$' { $report.ErrorCleared = $true }
            '^DEMO refusal mana_before=(\d+) mana_after=(\d+) begins=(\d+)\s*$' {
                $report.ManaBefore = [int]$Matches[1]
                $report.ManaAfter = [int]$Matches[2]
                $report.NoDebit = ([int]$Matches[1] -eq [int]$Matches[2] -and [int]$Matches[3] -eq 0)
            }
            '^DEMO cooldown_refuse heal ' { $report.CooldownHealRefused = $true }
            '^DEMO cooldown_welcome fireball=\d+ heal=\d+\s*$' { $report.CooldownWelcome = $true }
            '^DEMO cooldown_cancel fireball remaining=0\s*$' { $report.CooldownCancelled = $true }
            '^DEMO cooldown_after_ready fireball cooldown=75\s*$' { $report.CooldownAfterReady = $true }
            '^DEMO cooldown_resolve (fireball|heal) cooldown=(75|38)\s*$' { $report.CooldownResolves.Add("$($Matches[1])=$($Matches[2])") }
            '^DEMO sweep (appearing|draining|idle|resync|re-anchor|clear)\b' { $report.SweepStates.Add($Matches[1]) }
            '^DEMO hotbar_press slot=\d+ ability=(\S+)\s*$' { $report.HotbarPresses.Add($Matches[1]) }
        }
    }
    return $report
}

try {
    $null = Initialize-MarqueEvidenceDir -OutDir $OutDir -SourceScript "scripts/cast_bar_demo.ps1"

    Write-Host "==> building marqued"
    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    Write-Host "==> warming the Godot import cache"
    $warm = Start-Process -FilePath $Godot `
        -ArgumentList @("--headless", "--path", ('"' + $clientDir + '"'), "--quit-after", "20") `
        -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput (Join-Path $OutDir "warm.stdout.log") `
        -RedirectStandardError (Join-Path $OutDir "warm.stderr.log")
    if ($warm.ExitCode -ne 0) { throw "the Godot warm-up run exited $($warm.ExitCode)" }

    Write-Host "==> starting marqued on a free port (-admin; kit via client /give)"
    $serverArgs = @("-addr", "127.0.0.1:0", "-admin")
    if ($OutOfMana) { $serverArgs += @("-start-mana", "0") }
    $server = Start-Process -FilePath $binary `
        -ArgumentList $serverArgs `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
    $null = $server.Handle

    $address = $null
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($server.HasExited) { throw "marqued exited with code $($server.ExitCode) before it announced an address" }
        if (Test-Path $serverOut) {
            $line = Select-String -Path $serverOut -Pattern '"ev":"server_started"' -List
            if ($null -ne $line) {
                if ($line.Line -match '"addr":"([^"]+)"') { $address = $Matches[1]; break }
                throw "server_started carried no addr: $($line.Line)"
            }
        }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $address) { throw "marqued never logged server_started within $ReadyTimeoutSeconds seconds" }
    $url = "ws://$address/ws"
    Write-Host "==> marqued listening at $url (pid $($server.Id))"

    Write-Host "==> launching cast-bar client"
    $clientArgs = @(
        "--path", ('"' + $clientDir + '"'),
        "--position", "40,60",
        "--",
        "--server", $url,
        "--cast-bar-shots", ('"' + $prefix + '"')
    )
    if ($YawSamples) { $clientArgs += "--yaw-samples" }
    if ($CooldownProof) { $clientArgs += "--cast-bar-cooldown-proof" }
    if ($RefusalDemo) { $clientArgs += "--cast-bar-refusal-demo" }
    if ($OutOfMana) { $clientArgs += "--cast-bar-oom-demo" }
    if ($Sweep) { $clientArgs += "--cast-bar-sweep-demo" }
    $client = Start-Process -FilePath $Godot -NoNewWindow -PassThru `
        -ArgumentList $clientArgs `
        -RedirectStandardOutput $clientOut -RedirectStandardError $clientErr
    $null = $client.Handle
    if ($client.WaitForExit($ClientTimeoutSeconds * 1000)) {
        $client.WaitForExit()
    } else {
        Add-Failure "client did not finish within $ClientTimeoutSeconds seconds"
        Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
    }

    Show-File "client stdout" $clientOut
    Show-File "client stderr" $clientErr
    if ($client.HasExited) {
        $code = $client.ExitCode
        if ($null -eq $code) {
            Add-Failure "client exit code could not be read"
        } elseif ($code -ne 0) {
            Add-Failure "client exited $code"
        }
    }

    $report = Read-ClientReport $clientOut
    if ($report.Joined -lt 1) { Add-Failure "client never reported DEMO joined" }
    foreach ($reason in $report.Failures) { Add-Failure "client reported DEMO FAIL: $reason" }
    if (-not $report.Done) { Add-Failure "client never reported DEMO done" }
    if ($YawSamples -and (-not $report.YawBeforeMid -or -not $report.YawAfter)) { Add-Failure "missing cast yaw before/mid/after samples" }
    if (-not $OutOfMana -and -not $report.CastOk) { Add-Failure "missing DEMO castok" }
    if (-not $Sweep -and -not $RefusalDemo -and -not $OutOfMana -and -not $report.CastCancel) { Add-Failure "missing DEMO castcancel" }
    if (-not $Sweep -and -not $OutOfMana -and -not $report.CastBarVisible) { Add-Failure "missing DEMO castbar visible=1" }
    if (-not $Sweep -and -not $OutOfMana -and -not $report.CastBarHidden) { Add-Failure "missing DEMO castbar visible=0" }
    if (-not $OutOfMana -and ($report.HotbarPresses.Count -lt 2 -or $report.HotbarPresses -contains "")) { Add-Failure "demo cast did not press abilities through the hotbar" }
    if ($Sweep) {
        foreach ($state in @("appearing", "draining", "idle", "resync", "re-anchor", "clear")) {
            if (-not $report.SweepStates.Contains($state)) { Add-Failure "missing DEMO sweep $state observation" }
        }
    }
    if ($OutOfMana) {
        if (-not $report.OutOfRangeReason -or -not $report.InsufficientManaReason) { Add-Failure "missing decoded out_of_range/insufficient_mana DEMO refusal" }
        if (-not $report.ErrorText -or -not $report.ErrorCleared) { Add-Failure "missing refusal HUD text/clear markers" }
        if (-not $report.ErrorTintRange -or -not $report.ErrorTintMana) { Add-Failure "missing reason-specific HUD tint markers" }
        if (-not $report.NoDebit -or $report.ManaBefore -ge 25) { Add-Failure "mana changed, was insufficiently low, or cast_begin followed a refused press" }
    }
    if ($CooldownProof) {
        if (-not $report.CooldownFirstReady) { Add-Failure "missing DEMO cooldown first_ready" }
        if (-not $report.CooldownFireballRefused) { Add-Failure "missing DEMO fireball cooldown refusal" }
        if (-not $report.CooldownHealRefused) { Add-Failure "missing DEMO heal cooldown refusal" }
        if (-not $report.CooldownWelcome) { Add-Failure "missing DEMO cooldown welcome resync" }
        if (-not $report.CooldownCancelled) { Add-Failure "missing DEMO cancelled cast has no cooldown" }
        if (-not $report.CooldownAfterReady) { Add-Failure "missing DEMO after-ready fireball resolve" }
        foreach ($expected in @("fireball=75", "heal=38")) {
            if (-not $report.CooldownResolves.Contains($expected)) { Add-Failure "missing DEMO resolve cooldown $expected" }
        }
    }

    # PNG artifacts only (ARM-289); DEMO cast lines + GAMELOG are the proof.
    $shotCount = if ($Sweep) { 6 } elseif ($OutOfMana) { 2 } elseif ($RefusalDemo) { 1 } else { 3 }
    foreach ($index in 1..$shotCount) {
        $shot = "${prefix}_$index.png"
        if (Test-Path $shot) {
            $size = (Get-Item $shot).Length
            Write-Host "==> $shot ($size bytes, artifact)"
        }
    }

    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) { Add-Failure "the server wrote no GAMELOG events" }

    $player = $report.Joined
    if ($player -ge 1) {
        $begin = Select-Events $events "cast_begin" $player
        $cast = Select-Events $events "cast" $player
        $effect = Select-Events $events "cast_effect" $player
        $cancelled = Select-Events $events "cast_cancelled" $player
        $moveCancel = @($cancelled | Where-Object { [string]$_.cause -eq "move" })
        if ($OutOfMana) {
            $rejected = Select-Events $events "cast_rejected" $player
            $oor = @($rejected | Where-Object { [string]$_.reason -eq "out_of_range" })
            $oom = @($rejected | Where-Object { [string]$_.reason -eq "insufficient_mana" })
            $spends = Select-Events $events "mana_spend" $player
            if ($begin.Count -ne 0 -or $cast.Count -ne 0) { Add-Failure "OOM/OOR generated cast_begin=$($begin.Count) cast=$($cast.Count)" }
            if ($oor.Count -ne 1 -or $oom.Count -ne 1 -or $rejected.Count -ne 2) { Add-Failure "cast_rejected OOR=$($oor.Count) OOM=$($oom.Count) total=$($rejected.Count), want 1 each" }
            if ($spends.Count -ne 0) { Add-Failure "refused OOM/OOR spent mana $($spends.Count) time(s)" }
        } elseif ($Sweep) {
            $fireballBegin = @($begin | Where-Object { [string]$_.ability -eq "fireball" })
            $fireballCast = @($cast | Where-Object { [string]$_.ability -eq "fireball" })
            if ($fireballBegin.Count -ne 2 -or $fireballCast.Count -ne 2) { Add-Failure "sweep server fireball begin=$($fireballBegin.Count) resolve=$($fireballCast.Count), want 2 each" }
            $cancelled = Select-Events $events "cast_cancelled" $player
            if ($cancelled.Count -ne 0) { Add-Failure "sweep unexpectedly cancelled a cast" }
        } elseif ($RefusalDemo) {
            if ($begin.Count -ne 1 -or $cast.Count -ne 1) { Add-Failure "refusal phase successful begin=$($begin.Count) cast=$($cast.Count), want 1 each" }
            $rejected = Select-Events $events "cast_rejected" $player
            $cooldownRejected = @($rejected | Where-Object { [string]$_.reason -eq "cooldown" })
            if ($rejected.Count -ne 1 -or $cooldownRejected.Count -ne 1) { Add-Failure "refusal phase cast_rejected cooldown=$($cooldownRejected.Count)/total=$($rejected.Count), want 1" }
            if (-not $report.CooldownReason) { Add-Failure "client did not decode cooldown reason" }
            if (-not $report.ErrorText -or -not $report.ErrorCleared) { Add-Failure "error HUD text/linger markers missing" }
        } elseif ($CooldownProof) {
            $fireballBegin = @($begin | Where-Object { [string]$_.ability -eq "fireball" })
            $healBegin = @($begin | Where-Object { [string]$_.ability -eq "heal" })
            $fireballCast = @($cast | Where-Object { [string]$_.ability -eq "fireball" })
            $healCast = @($cast | Where-Object { [string]$_.ability -eq "heal" })
            $spends = Select-Events $events "mana_spend" $player
            if ($fireballBegin.Count -ne 4) { Add-Failure "fireball cast_begin=$($fireballBegin.Count), want 4 (first, after-ready, cancelled, final)" }
            if ($healBegin.Count -ne 0) { Add-Failure "heal cast_begin=$($healBegin.Count), want 0 for instant heal" }
            if ($fireballCast.Count -ne 3 -or $healCast.Count -ne 1) { Add-Failure "resolved casts fireball=$($fireballCast.Count), heal=$($healCast.Count), want 3 and 1" }
            if ($spends.Count -ne 4) { Add-Failure "mana_spend=$($spends.Count), want 4 successful resolves only" }
            if ($moveCancel.Count -ne 1) { Add-Failure "cast_cancelled cause=move=$($moveCancel.Count), want 1" }
            $rejected = Select-Events $events "cast_rejected" $player
            $cooldownRejected = @($rejected | Where-Object { [string]$_.reason -eq "cooldown" })
            if ($rejected.Count -ne 2 -or $cooldownRejected.Count -ne 2) { Add-Failure "cast_rejected cooldown=$($cooldownRejected.Count)/total=$($rejected.Count), want exactly 2 cooldown refusals" }
        } else {
            if ($begin.Count -lt 2) { Add-Failure "cast_begin=$($begin.Count), want >= 2 (resolve + interrupt)" }
            if ($cast.Count -lt 1) {
                Add-Failure "cast=$($cast.Count), want >= 1 resolve"
            } elseif ([string]$cast[0].ability -ne "fireball") {
                Add-Failure "cast ability '$($cast[0].ability)', want fireball"
            }
            if ($effect.Count -lt 1) { Add-Failure "cast_effect=$($effect.Count), want >= 1" }
            if ($moveCancel.Count -lt 1) {
                Add-Failure "cast_cancelled with cause=move=$($moveCancel.Count), want >= 1"
            } else {
                Write-Host "==> server: player $player cast_cancelled cause=$($moveCancel[0].cause)"
            }
            $rejected = Select-Events $events "cast_rejected"
            if ($rejected.Count -gt 0) { Add-Failure "the server logged $($rejected.Count) cast_rejected event(s)" }
        }
    }
} catch {
    Add-Failure "$($_.Exception.Message)"
} finally {
    if ($null -ne $server) {
        if ($server.HasExited) {
            Add-Failure "marqued exited on its own with code $($server.ExitCode)"
        } else {
            Write-Host "==> stopping marqued (pid $($server.Id))"
            Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
            $server.WaitForExit(5000) | Out-Null
        }
    }
    if (Test-Path $serverErr) {
        $stderrText = Get-Content -Path $serverErr -Raw
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            $firstLine = $stderrText.Trim() -split "`r?`n" | Select-Object -First 1
            Add-Failure "marqued wrote to stderr: $firstLine"
        }
    }
    Show-File "marqued event log ($serverOut)" $serverOut
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-MarqueDemoResult `
    -OkMarker "CAST BAR DEMO OK" `
    -FailMarker "CAST BAR DEMO FAILED" `
    -EvidenceLine "evidence (screenshots, client logs, server event log): $OutDir"
