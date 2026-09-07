[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-two-client"),
    [string] $ClickA = "0.30,0.72",
    [string] $ClickB = "0.70,0.72",
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$MinDisplacement = 2.0

$MinSeparation = 3.0

$StillCameraMinDiff = 0.002
$StillCameraMaxDiff = 0.10
$SkyBandControlFailure = "the background is not a control"
$SkyBandFlakeMaxStillFraction = $StillCameraMaxDiff

$MovingCameraDiffRatio = 8.0

$ExpectedTickMS = 150
$ExpectedWalkSpeed = 3.0

$MaxWalkTickError = 2

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-demo-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
$evidenceMarker = Join-Path $OutDir ".marque-evidence"

$MaxLayerDisagreement = 0.05

$server = $null
$failures = New-Object System.Collections.Generic.List[string]
$stillFractions = New-Object System.Collections.Generic.List[double]

function Show-File([string] $label, [string] $path) {
    if (-not (Test-Path $path)) { return }
    $content = Get-Content -Path $path -Raw
    if ([string]::IsNullOrWhiteSpace($content)) { return }
    Write-Host ""
    Write-Host "--- $label ---"
    Write-Host $content.TrimEnd()
}

function Read-Positions([string] $path) {
    $byShot = @{}
    if (-not (Test-Path $path)) { return $byShot }
    foreach ($line in Get-Content -Path $path) {
        if ($line -match '^DEMO pos (\d+) (\d+) (-?[0-9.eE+-]+) (-?[0-9.eE+-]+)\s*$') {
            $shot = [int]$Matches[1]
            if (-not $byShot.ContainsKey($shot)) { $byShot[$shot] = @{} }
            $byShot[$shot][[int]$Matches[2]] = [double[]] @([double]$Matches[3], [double]$Matches[4])
        }
    }
    return $byShot
}

function Compare-Frames([string] $left, [string] $right) {
    Add-Type -AssemblyName System.Drawing
    $a = [System.Drawing.Bitmap]::FromFile($left)
    $b = [System.Drawing.Bitmap]::FromFile($right)
    try {
        if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) {
            throw "frames differ in size: $left is $($a.Width)x$($a.Height), $right is $($b.Width)x$($b.Height)"
        }
        $rect = New-Object System.Drawing.Rectangle 0, 0, $a.Width, $a.Height
        $format = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        $mode = [System.Drawing.Imaging.ImageLockMode]::ReadOnly
        $la = $a.LockBits($rect, $mode, $format)
        $lb = $b.LockBits($rect, $mode, $format)
        $count = $la.Stride * $a.Height
        $bytesA = New-Object byte[] $count
        $bytesB = New-Object byte[] $count
        [System.Runtime.InteropServices.Marshal]::Copy($la.Scan0, $bytesA, 0, $count)
        [System.Runtime.InteropServices.Marshal]::Copy($lb.Scan0, $bytesB, 0, $count)
        $a.UnlockBits($la)
        $b.UnlockBits($lb)

        $md5 = [System.Security.Cryptography.MD5]::Create()
        $identical = [System.BitConverter]::ToString($md5.ComputeHash($bytesA)) -eq
                     [System.BitConverter]::ToString($md5.ComputeHash($bytesB))

        $bandBytes = $la.Stride * [int]($a.Height / 4)
        $bandIdentical = [System.BitConverter]::ToString($md5.ComputeHash($bytesA, 0, $bandBytes)) -eq
                         [System.BitConverter]::ToString($md5.ComputeHash($bytesB, 0, $bandBytes))

        $sampled = 0
        $differing = 0
        for ($i = 0; $i -lt ($count - 3); $i += 32) {
            $sampled++
            if ($bytesA[$i] -ne $bytesB[$i] -or
                $bytesA[$i + 1] -ne $bytesB[$i + 1] -or
                $bytesA[$i + 2] -ne $bytesB[$i + 2]) {
                $differing++
            }
        }
        return @{
            Identical = $identical
            Fraction = $differing / [double]$sampled
            BandIdentical = $bandIdentical
        }
    } finally {
        $a.Dispose()
        $b.Dispose()
    }
}

function Test-SkyBandFlakeCandidate {
    param(
        [System.Collections.Generic.List[string]] $FailureList,
        [System.Collections.Generic.List[double]] $FractionList,
        [string] $Needle,
        [double] $MaxStillFraction
    )
    if ($FailureList.Count -lt 1) { return $false }
    if ($FractionList.Count -lt 1) { return $false }
    foreach ($failure in $FailureList) {
        if ($failure -notlike "*$Needle*") { return $false }
    }
    foreach ($fraction in $FractionList) {
        if ($fraction -gt $MaxStillFraction) { return $false }
    }
    return $true
}

function Get-JoinedId([string] $path) {
    if (-not (Test-Path $path)) { return -1 }
    foreach ($line in Get-Content -Path $path) {
        if ($line -match '^DEMO joined (\d+)\s*$') { return [int]$Matches[1] }
    }
    return -1
}

function Read-GameLog([string] $path) {
    $events = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $path)) { return , $events }
    foreach ($line in Get-Content -Path $path) {
        if (-not $line.StartsWith("GAMELOG ")) { continue }
        $events.Add(($line.Substring(8) | ConvertFrom-Json))
    }
    return , $events
}

function Select-PlayerEvents($events, [string] $kind, [int] $player) {
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($event in $events) {
        if ($event.ev -ne $kind) { continue }
        if ($event.PSObject.Properties.Name -notcontains "player") { continue }
        if ([int]$event.player -ne $player) { continue }
        $hits.Add($event)
    }
    return , $hits
}

function Get-Distance([double] $ax, [double] $az, [double] $bx, [double] $bz) {
    return [math]::Sqrt([math]::Pow($ax - $bx, 2) + [math]::Pow($az - $bz, 2))
}

try {
    if (Test-Path $OutDir) {
        $stale = @(Get-ChildItem -LiteralPath $OutDir -Force)
        if ($stale.Count -gt 0) {
            if (-not (Test-Path $evidenceMarker)) {
                throw ("$OutDir is not empty and carries no .marque-evidence marker, so this " +
                       "script did not write it; refusing to clear it or to run beside it. " +
                       "Pass -OutDir somewhere else, or empty it yourself.")
            }
            Write-Host "==> clearing $($stale.Count) leftover item(s) from $OutDir"
            Remove-Item -LiteralPath $stale.FullName -Recurse -Force
        }
    } else {
        New-Item -ItemType Directory -Path $OutDir | Out-Null
    }
    Set-Content -LiteralPath $evidenceMarker -Encoding utf8 `
        -Value "Evidence from scripts/two_client_demo.ps1. Its next run empties this directory."

    Write-Host "==> building marqued"
    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    Write-Host "==> warming the Godot import cache"
    # Whichever process imports first writes client/.godot. Two doing it at once
    # race, and the loser's assets can come up missing.
    $warm = Start-Process -FilePath $Godot `
        -ArgumentList @("--headless", "--path", ('"' + $clientDir + '"'), "--quit-after", "20") `
        -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput (Join-Path $OutDir "warm.stdout.log") `
        -RedirectStandardError (Join-Path $OutDir "warm.stderr.log")
    if ($warm.ExitCode -ne 0) {
        throw "the Godot warm-up run exited $($warm.ExitCode); see warm.stderr.log in $OutDir"
    }

    Write-Host "==> starting marqued on a free port"
    $server = Start-Process -FilePath $binary `
        -ArgumentList "-addr", "127.0.0.1:0" `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
    $null = $server.Handle

    $address = $null
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($server.HasExited) {
            throw "marqued exited with code $($server.ExitCode) before it announced an address"
        }
        if (Test-Path $serverOut) {
            $line = Select-String -Path $serverOut -Pattern '"ev":"server_started"' -List
            if ($null -ne $line) {
                if ($line.Line -match '"addr":"([^"]+)"') { $address = $Matches[1]; break }
                throw "server_started carried no addr: $($line.Line)"
            }
        }
        Start-Sleep -Milliseconds 25
    }
    if (-not $address) {
        throw "marqued did not announce a listening address within $ReadyTimeoutSeconds seconds"
    }
    $url = "ws://$address/ws"
    Write-Host "==> marqued listening, url $url"
    Write-Host "==> screenshots will land in $OutDir"

    $clients = @(
        @{ Label = "a"; Click = $ClickA; Phase = 1; Position = "40,60" },
        @{ Label = "b"; Click = $ClickB; Phase = 2; Position = "700,140" }
    )

    $running = @()
    foreach ($client in $clients) {
        $prefix = Join-Path $OutDir $client.Label
        $stdout = Join-Path $OutDir ("client-" + $client.Label + ".stdout.log")
        $stderr = Join-Path $OutDir ("client-" + $client.Label + ".stderr.log")
        $godotArgs = @(
            "--path", ('"' + $clientDir + '"'),
            "--position", $client.Position,
            "--",
            "--server", $url,
            "--shots", ('"' + $prefix + '"')
        )
        if ($client.Click) {
            $godotArgs += @("--click", $client.Click, "--phase", $client.Phase.ToString())
        }

        Write-Host "==> launching client $($client.Label)"
        $process = Start-Process -FilePath $Godot -ArgumentList $godotArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null = $process.Handle
        $running += @{
            Label = $client.Label
            Process = $process
            Stdout = $stdout
            Stderr = $stderr
            Prefix = $prefix
            Phase = $client.Phase
            Click = $client.Click
            Id = -1
            Positions = $null
        }
    }

    foreach ($client in $running) {
        if ($client.Process.WaitForExit($ClientTimeoutSeconds * 1000)) {
            $client.Process.WaitForExit()
        } else {
            $failures.Add("client $($client.Label) did not finish within $ClientTimeoutSeconds seconds")
            Stop-Process -Id $client.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($client in $running) {
        $client.Id = Get-JoinedId $client.Stdout
        if ($client.Id -lt 1) {
            $failures.Add("client $($client.Label) never reported the id it joined as")
        }
    }
    $walkerOfPhase = @{}
    foreach ($client in $running) { $walkerOfPhase[$client.Phase] = $client.Id }

    foreach ($client in $running) {
        $label = $client.Label
        Show-File "client $label stdout" $client.Stdout
        if ($client.Process.HasExited) {
            $code = $client.Process.ExitCode
            if ($null -eq $code) {
                $failures.Add("client $label's exit code could not be read")
            } elseif ($code -ne 0) {
                $failures.Add("client $label exited $code")
            }
        }
        $stdoutText = ""
        if (Test-Path $client.Stdout) { $stdoutText = Get-Content -Path $client.Stdout -Raw }
        if ($stdoutText -notmatch "DEMO done") {
            $failures.Add("client $label never reported 'DEMO done'")
        }

        $frames = @{}
        foreach ($index in 1, 2, 3, 4) {
            $shot = "$($client.Prefix)_$index.png"
            if (-not (Test-Path $shot)) {
                $failures.Add("client $label never wrote $shot")
                continue
            }
            $frames[$index] = $shot
            $size = (Get-Item $shot).Length
            Write-Host "==> $shot ($size bytes)"
            if ($size -lt 4096) { $failures.Add("$shot is only $size bytes; that is not a frame") }
        }

        $positions = Read-Positions $client.Stdout
        $client.Positions = $positions
        foreach ($index in 1, 2, 3, 4) {
            if (-not $positions.ContainsKey($index)) {
                $failures.Add("client $label reported no bodies for shot $index")
                continue
            }
            $drawn = $positions[$index].Keys.Count
            if ($drawn -ne 2) {
                $failures.Add("client $label drew $drawn body/bodies in shot $index; the milestone is two")
            }
        }
        if ($positions.Keys.Count -lt 4 -or $client.Id -lt 1) { continue }

        foreach ($phase in 1, 2) {
            $walker = $walkerOfPhase[$phase]
            $first = 2 * $phase - 1
            $last = 2 * $phase
            if (-not $positions[$first].ContainsKey($walker) -or
                -not $positions[$last].ContainsKey($walker)) {
                $failures.Add("client $label did not draw player $walker in shots $first and $last")
                continue
            }
            $before = $positions[$first][$walker]
            $after = $positions[$last][$walker]
            $moved = [math]::Sqrt([math]::Pow($after[0] - $before[0], 2) + [math]::Pow($after[1] - $before[1], 2))
            $whose = if ($walker -eq $client.Id) { "itself" } else { "the other player" }
            Write-Host ("==> client {0} phase {1}: {2} (player {3}) moved {4:N3} units, ({5:N3}, {6:N3}) -> ({7:N3}, {8:N3})" -f `
                $label, $phase, $whose, $walker, $moved, $before[0], $before[1], $after[0], $after[1])
            if ($moved -lt $MinDisplacement) {
                $failures.Add("client $label saw $whose (player $walker) move only $([math]::Round($moved, 3)) units across shots $first..$last")
            }
        }

        $mine = $positions[4][$client.Id]
        $theirs = $null
        foreach ($id in $positions[4].Keys) { if ($id -ne $client.Id) { $theirs = $positions[4][$id] } }
        if ($null -ne $theirs) {
            $apart = [math]::Sqrt([math]::Pow($mine[0] - $theirs[0], 2) + [math]::Pow($mine[1] - $theirs[1], 2))
            Write-Host ("==> client {0}: the two destinations are {1:N3} units apart" -f $label, $apart)
            if ($apart -lt $MinSeparation) {
                $failures.Add("client $label ended with the two players only $([math]::Round($apart, 3)) units apart; the walks are confusable")
            }
        }

        if ($frames.Keys.Count -lt 4) { continue }

        $watching = 3 - $client.Phase
        $stillPair = Compare-Frames $frames[2 * $watching - 1] $frames[2 * $watching]
        $movingPair = Compare-Frames $frames[2 * $client.Phase - 1] $frames[2 * $client.Phase]
        Write-Host ("==> client {0} pixels: standing still (shots {1}..{2}) {3:P2} differ, sky band identical={4}; walking (shots {5}..{6}) {7:P2} differ, sky band identical={8}" -f `
            $label, (2 * $watching - 1), (2 * $watching), $stillPair.Fraction, $stillPair.BandIdentical,
            (2 * $client.Phase - 1), (2 * $client.Phase), $movingPair.Fraction, $movingPair.BandIdentical)

        if ($stillPair.Fraction -lt $StillCameraMinDiff) {
            $failures.Add("client $label's still-camera frames are $([math]::Round($stillPair.Fraction * 100, 3))% different; the other player did not visibly move")
        }
        if ($stillPair.Fraction -gt $StillCameraMaxDiff) {
            $failures.Add("client $label's still-camera frames are $([math]::Round($stillPair.Fraction * 100, 1))% different; more than the other player's body moved")
        }
        if (-not $stillPair.BandIdentical) {
            $failures.Add("client $label stood still but the top quarter of its two frames differs; $SkyBandControlFailure")
            $stillFractions.Add($stillPair.Fraction)
        }
        if ($movingPair.BandIdentical) {
            $failures.Add("client $label walked but the top quarter of its two frames is identical; the camera did not follow it")
        }
        if ($movingPair.Fraction -lt ($MovingCameraDiffRatio * $stillPair.Fraction)) {
            $failures.Add("client $label's walking frames differ only $([math]::Round($movingPair.Fraction / $stillPair.Fraction, 1))x as much as its standing-still frames")
        }
    }

    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) {
        $failures.Add("the server wrote no GAMELOG events to $serverOut; this run contains no server-side evidence at all")
    }

    $perTick = $ExpectedWalkSpeed * $ExpectedTickMS / 1000.0
    $started = @($events | Where-Object { $_.ev -eq "server_started" })
    if ($started.Count -ne 1) {
        $failures.Add("the log holds $($started.Count) server_started event(s), want 1")
    } else {
        $boot = $started[0]
        if ([int]$boot.tick_ms -ne $ExpectedTickMS) {
            $failures.Add("the server ticks every $($boot.tick_ms)ms; this script's walk durations assume $ExpectedTickMS")
        }
        if ([double]$boot.walk_speed -ne $ExpectedWalkSpeed) {
            $failures.Add("the server walks at $($boot.walk_speed) units/s; this script's walk durations assume $ExpectedWalkSpeed")
        }
        $perTick = [double]$boot.walk_speed * [int]$boot.tick_ms / 1000.0
    }

    $arrivedAt = @{}
    foreach ($client in $running) {
        $label = $client.Label
        if ($client.Id -lt 1) { continue }
        $id = $client.Id

        if ((Select-PlayerEvents $events "client_connected" $id).Count -lt 1) {
            $failures.Add("client $label reported joining as player $id but the server logged no client_connected for it")
        }
        if ([string]::IsNullOrWhiteSpace($client.Click)) { continue }

        if ((Select-PlayerEvents $events "move_to" $id).Count -lt 1) {
            $failures.Add("client $label clicked but the server logged no move_to for player $id; the intent never reached it")
        }

        $assigned = Select-PlayerEvents $events "path_assigned" $id
        if ($assigned.Count -lt 1) {
            $failures.Add("the server assigned player $id (client $label) no path; there was nothing for anyone to walk")
            continue
        }
        $path = $assigned[$assigned.Count - 1]
        if ($path.points.Count -lt 2) {
            $failures.Add("player $id's path_assigned carries $($path.points.Count) point(s); a walk needs at least two")
            continue
        }
        $from = $path.points[0]
        $to = $path.points[$path.points.Count - 1]
        $span = Get-Distance ([double]$from[0]) ([double]$from[1]) ([double]$to[0]) ([double]$to[1])
        if ($span -lt $MinDisplacement) {
            $failures.Add("player $id's assigned path spans only $([math]::Round($span, 3)) units; the server did not plan the walk the client asked for")
        }

        $arrived = $null
        foreach ($candidate in (Select-PlayerEvents $events "arrived" $id)) {
            if ($candidate.t -le $path.start_tick) { continue }
            if ((Get-Distance ([double]$candidate.x) ([double]$candidate.z) ([double]$to[0]) ([double]$to[1])) -gt 1e-6) { continue }
            $arrived = $candidate
            break
        }
        if ($null -eq $arrived) {
            $seen = (Select-PlayerEvents $events "arrived" $id).Count
            $failures.Add(("the server never recorded player $id (client $label) arriving at " +
                "($([math]::Round([double]$to[0], 3)), $([math]::Round([double]$to[1], 3))), the endpoint of the path it assigned " +
                "at tick $($path.start_tick); the whole log holds $seen arrived event(s) for that player. " +
                "The clients walked the polyline they were handed, but the server's world never moved."))
            continue
        }
        $took = [int]$arrived.t - [int]$path.start_tick
        $expected = [int][math]::Ceiling($span / $perTick)
        Write-Host ("==> server: player {0} got a {1:N3}-unit path at tick {2} and arrived at ({3:N3}, {4:N3}) on tick {5}, {6} tick(s) later; walking that far takes {7}" -f `
            $id, $span, $path.start_tick, [double]$arrived.x, [double]$arrived.z, $arrived.t, $took, $expected)
        if ([math]::Abs($took - $expected) -gt $MaxWalkTickError) {
            $failures.Add(("player $id (client $label) crossed $([math]::Round($span, 3)) units in $took tick(s), " +
                "but at $ExpectedWalkSpeed units per second on ${ExpectedTickMS}ms ticks that walk takes $expected. " +
                "The server's world did not walk the path, it jumped it."))
        }
        $arrivedAt[$id] = [double[]] @([double]$arrived.x, [double]$arrived.z)
    }

    $walker1 = $walkerOfPhase[1]
    if ($null -ne $walker1 -and $arrivedAt.ContainsKey($walker1)) {
        $end = $arrivedAt[$walker1]
        foreach ($client in $running) {
            if ($null -eq $client.Positions) { continue }
            if (-not $client.Positions.ContainsKey(4)) { continue }
            if (-not $client.Positions[4].ContainsKey($walker1)) { continue }
            $drawn = $client.Positions[4][$walker1]
            $gap = Get-Distance $drawn[0] $drawn[1] $end[0] $end[1]
            Write-Host ("==> client {0} drew player {1} {2:N4} units from where the server says it stopped" -f `
                $client.Label, $walker1, $gap)
            if ($gap -gt $MaxLayerDisagreement) {
                $failures.Add(("client $($client.Label) drew player $walker1 at " +
                    "($([math]::Round($drawn[0], 3)), $([math]::Round($drawn[1], 3))) in shot 4, but the server recorded it " +
                    "arriving at ($([math]::Round($end[0], 3)), $([math]::Round($end[1], 3))): " +
                    "$([math]::Round($gap, 3)) units apart"))
            }
        }
    }
} catch {
    $failures.Add("$($_.Exception.Message) [$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())]")
} finally {
    if ($null -ne $server) {
        if ($server.HasExited) {
            $failures.Add("marqued exited on its own with code $($server.ExitCode); it must outlive the clients")
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
            $failures.Add("marqued wrote to stderr: $firstLine")
        }
    }
    Show-File "marqued event log ($serverOut)" $serverOut
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "evidence (screenshots, client logs, server event log): $OutDir"
if ($failures.Count -eq 0) {
    Write-Host "TWO CLIENT DEMO OK"
    exit 0
}
Write-Host "TWO CLIENT DEMO FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
if (Test-SkyBandFlakeCandidate -FailureList $failures -FractionList $stillFractions -Needle $SkyBandControlFailure -MaxStillFraction $SkyBandFlakeMaxStillFraction) {
    $shown = ($stillFractions | ForEach-Object { "{0:P2}" -f $_ }) -join ", "
    Write-Host ("SKY-BAND FLAKE CANDIDATE: only the still-camera sky-band control failed (still fraction {0}). Compare DEMO pos and path geometry to a green idle base, then rerun two_client_demo.ps1 on an idle machine before treating this as a product regression." -f $shown)
}
exit 1
