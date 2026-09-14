[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-contested-pickup"),
    [double] $ItemX = -5.0,
    [double] $ItemZ = -5.0,
    [string] $DropClick = "0.30,0.62",
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 150,
    # Demo-only: if GAMELOG pickup intents land on different ticks, re-run the
    # whole contest. The same-tick assert is never weakened — only retried.
    [int] $MaxContestAttempts = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ExpectedTickMS = 40
$ExpectedWalkSpeed = 3.0
$ExpectedInventorySize = 28

$LogCoordinateEpsilon = 1e-6

$MaxLayerDisagreement = 0.05
# walkaway_arrived is client display pose after soft-pull settle; item_spawned is
# server underfoot. Soft-pull can still leave ~1u residual (HARD_ERROR_M is 2.0).
# Keep the tighter epsilon for DEMO item ↔ item_spawned layer agreement.
$MaxWalkAwayDropDisagreement = 1.5

$MinDropDisplacement = 2.0

$MaxAimTickSkew = 1
# fire_unix_msec is Unix epoch millis — exceeds Int32.
$MaxFireDeadlineSkewMsec = 1

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$ContestAttempt = 1
if ($env:MARQUE_CONTEST_ATTEMPT -match '^\d+$') {
    $ContestAttempt = [Math]::Max(1, [int]$env:MARQUE_CONTEST_ATTEMPT)
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-pickup-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
$evidenceMarker = Join-Path $OutDir ".marque-evidence"

$server = $null
$failures = New-Object System.Collections.Generic.List[string]
$splitTickRetry = $false
$splitTickA = -1
$splitTickB = -1

function Add-Failure([string] $message) { $failures.Add($message) }

function Show-File([string] $label, [string] $path) {
    if (-not (Test-Path $path)) { return }
    $content = Get-Content -Path $path -Raw
    if ([string]::IsNullOrWhiteSpace($content)) { return }
    Write-Host ""
    Write-Host "--- $label ---"
    Write-Host $content.TrimEnd()
}

function Get-Distance([double] $ax, [double] $az, [double] $bx, [double] $bz) {
    return [math]::Sqrt([math]::Pow($ax - $bx, 2) + [math]::Pow($az - $bz, 2))
}


function Read-ClientReport([string] $path) {
    $report = @{
        Joined = -1
        Failures = New-Object System.Collections.Generic.List[string]
        Done = $false
        SyncTick = -1
        ClickTick = [int64](-1)
        Outcome = -1
        SeedItem = $null
        Wish = $null
        WalkAwayArrived = $null
        PlayerCounts = @{}
        ItemCounts = @{}
        Items = @{}
        Inventory = @{}
        Slots = @{}
        Shots = @{}
    }
    if (-not (Test-Path $path)) { return $report }
    foreach ($line in Get-Content -Path $path) {
        switch -Regex ($line) {
            '^DEMO joined (\d+)\s*$' { $report.Joined = [int]$Matches[1] }
            '^DEMO FAIL (.+)$' { $report.Failures.Add($Matches[1].Trim()) }
            '^DEMO done\s*$' { $report.Done = $true }
            '^DEMO sync (-?\d+) (-?\d+)\s*$' {
                $report.SyncTick = [int]$Matches[1]
                $report.ClickTick = [int64]$Matches[2]
            }
            '^DEMO outcome (\d+)\s*$' { $report.Outcome = [int]$Matches[1] }
            '^DEMO wish (-?[0-9.eE+-]+) (-?[0-9.eE+-]+)\s*$' {
                $report.Wish = @([double]$Matches[1], [double]$Matches[2])
            }
            '^DEMO walkaway_arrived (-?[0-9.eE+-]+) (-?[0-9.eE+-]+)\s*$' {
                $report.WalkAwayArrived = @([double]$Matches[1], [double]$Matches[2])
            }
            '^DEMO seeditem (\d+) (\S+) (-?[0-9.eE+-]+) (-?[0-9.eE+-]+)\s*$' {
                $report.SeedItem = @{
                    Id = [int]$Matches[1]
                    Kind = $Matches[2]
                    X = [double]$Matches[3]
                    Z = [double]$Matches[4]
                }
            }
            '^DEMO shot (\d+) (.+)$' { $report.Shots[[int]$Matches[1]] = $Matches[2].Trim() }
            '^DEMO players (\d+) (\d+)\s*$' {
                $report.PlayerCounts[[int]$Matches[1]] = [int]$Matches[2]
            }
            '^DEMO items (\d+) (\d+)\s*$' {
                $report.ItemCounts[[int]$Matches[1]] = [int]$Matches[2]
            }
            '^DEMO item (\d+) (\d+) (\S+) (-?[0-9.eE+-]+) (-?[0-9.eE+-]+)\s*$' {
                $shot = [int]$Matches[1]
                if (-not $report.Items.ContainsKey($shot)) { $report.Items[$shot] = @{} }
                $report.Items[$shot][[int]$Matches[2]] = @{
                    Kind = $Matches[3]
                    X = [double]$Matches[4]
                    Z = [double]$Matches[5]
                }
            }
            '^DEMO inv (\d+) (\d+) (\d+)\s*$' {
                $report.Inventory[[int]$Matches[1]] = @{
                    Occupied = [int]$Matches[2]
                    Size = [int]$Matches[3]
                }
            }
            '^DEMO invslot (\d+) (\d+) (\S+)\s*$' {
                $shot = [int]$Matches[1]
                if (-not $report.Slots.ContainsKey($shot)) { $report.Slots[$shot] = @{} }
                $report.Slots[$shot][[int]$Matches[2]] = $Matches[3]
            }
        }
    }
    return $report
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

function Test-HasField($event, [string] $name) {
    return $event.PSObject.Properties.Name -contains $name
}

function Select-Events($events, [string] $kind, [int] $player = -1, [int] $item = -1) {
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($event in $events) {
        if ($event.ev -ne $kind) { continue }
        if ($player -ge 0) {
            if (-not (Test-HasField $event "player")) { continue }
            if ([int]$event.player -ne $player) { continue }
        }
        if ($item -ge 0) {
            if (-not (Test-HasField $event "item")) { continue }
            if ([int]$event.item -ne $item) { continue }
        }
        $hits.Add($event)
    }
    return , $hits
}

function Count-PlayerPathAssigned($events) {
    $count = 0
    foreach ($event in $events) {
        if ($event.ev -ne "path_assigned") { continue }
        if (-not (Test-HasField $event "player")) { continue }
        if ($null -eq $event.player) { continue }
        $count++
    }
    return $count
}

function Count-NonzeroMoves($events, [int] $player = -1) {
    $count = 0
    foreach ($event in (Select-Events $events "move" $player)) {
        $dx = [double]$event.dx
        $dz = [double]$event.dz
        if ([math]::Sqrt(($dx)*($dx) + ($dz)*($dz)) -gt 1e-6) { $count++ }
    }
    return $count
}


try {
    Write-Host "==> contested pickup attempt $ContestAttempt/$MaxContestAttempts"
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
        -Value "Evidence from scripts/contested_pickup_demo.ps1. Its next run empties this directory."

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

    # Invariant culture: the server parses this with strconv.ParseFloat, which
    # wants a period. A machine set to a comma-decimal locale would otherwise
    # produce "-5,5" here and fail at startup with a syntax error nobody would
    # connect to the harness.
    $seed = [string]::Format([cultureinfo]::InvariantCulture, "{0},{1},acorn", $ItemX, $ItemZ)
    Write-Host "==> starting marqued on a free port with exactly one item at ($ItemX, $ItemZ)"
    $server = Start-Process -FilePath $binary `
        -ArgumentList @("-addr", "127.0.0.1:0", "-item", $seed) `
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

    $running = @()
    foreach ($spec in @(@{ Label = "a"; Position = "40,60" }, @{ Label = "b"; Position = "700,140" })) {
        $prefix = Join-Path $OutDir $spec.Label
        $stdout = Join-Path $OutDir ("client-" + $spec.Label + ".stdout.log")
        $stderr = Join-Path $OutDir ("client-" + $spec.Label + ".stderr.log")
        Write-Host "==> launching client $($spec.Label)"
        $process = Start-Process -FilePath $Godot -NoNewWindow -PassThru `
            -ArgumentList @(
                "--path", ('"' + $clientDir + '"'),
                "--position", $spec.Position,
                "--",
                "--server", $url,
                "--pickup-shots", ('"' + $prefix + '"'),
                "--drop-click", $DropClick
            ) `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null = $process.Handle
        $running += @{
            Label = $spec.Label; Process = $process; Stdout = $stdout
            Prefix = $prefix; Report = $null
        }
    }

    foreach ($client in $running) {
        if ($client.Process.WaitForExit($ClientTimeoutSeconds * 1000)) {
            $client.Process.WaitForExit()
        } else {
            Add-Failure "client $($client.Label) did not finish within $ClientTimeoutSeconds seconds"
            Stop-Process -Id $client.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($client in $running) {
        Show-File "client $($client.Label) stdout" $client.Stdout
        $client.Report = Read-ClientReport $client.Stdout
    }

    foreach ($client in $running) {
        $label = $client.Label
        $report = $client.Report
        if ($client.Process.HasExited) {
            $code = $client.Process.ExitCode
            if ($null -eq $code) {
                Add-Failure "client $label's exit code could not be read"
            } elseif ($code -ne 0) {
                Add-Failure "client $label exited $code"
            }
        }
        foreach ($reason in $report.Failures) {
            Add-Failure "client $label refused to drive the scenario: $reason"
        }
        if (-not $report.Done) { Add-Failure "client $label never reported 'DEMO done'" }
        if ($report.Joined -lt 1) {
            Add-Failure "client $label never reported the id it joined as"
        }
        foreach ($index in 1, 2, 3) {
            $shot = "$($client.Prefix)_$index.png"
            if (-not (Test-Path $shot)) {
                Add-Failure "client $label never wrote $shot"
                continue
            }
            $size = (Get-Item $shot).Length
            Write-Host "==> $shot ($size bytes)"
            if ($size -lt 4096) { Add-Failure "$shot is only $size bytes; that is not a frame" }
            if (-not $report.PlayerCounts.ContainsKey($index)) {
                Add-Failure "client $label reported no player count for shot $index"
            } elseif ($report.PlayerCounts[$index] -ne 2) {
                Add-Failure ("client $label drew $($report.PlayerCounts[$index]) player body/bodies " +
                    "in shot $index; the milestone is two")
            }
        }
    }

    $ids = @($running | ForEach-Object { $_.Report.Joined })
    if (@($ids | Where-Object { $_ -lt 1 }).Count -eq 0 -and $ids[0] -eq $ids[1]) {
        Add-Failure "both clients report joining as player $($ids[0]); they are not two players"
    }

    $clickTicks = @($running | ForEach-Object { [int64]$_.Report.ClickTick })
    Write-Host ("==> clients chose fire deadlines {0} and {1} (sync ticks {2} and {3})" -f `
        $clickTicks[0], $clickTicks[1], $running[0].Report.SyncTick, $running[1].Report.SyncTick)
    if ($clickTicks[0] -lt 0 -or $clickTicks[1] -lt 0) {
        Add-Failure "a client never reported the shared wall-clock fire deadline"
    } elseif ([math]::Abs($clickTicks[0] - $clickTicks[1]) -gt $MaxFireDeadlineSkewMsec) {
        Add-Failure ("the two clients disagreed on the shared wall-clock fire deadline: $($clickTicks[0]) vs " +
            "$($clickTicks[1]) (skew $([math]::Abs($clickTicks[0] - $clickTicks[1]))). DEMO sync's second " +
            "field is fire_unix_msec from the post-capture barrier; both must name the same moment.")
    }

    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) {
        Add-Failure ("the server wrote no GAMELOG events to $serverOut; this run contains no " +
            "server-side evidence at all")
    }

    $started = Select-Events $events "server_started"
    if ($started.Count -ne 1) {
        Add-Failure "the log holds $($started.Count) server_started event(s), want 1"
    } else {
        $boot = $started[0]
        if ([int]$boot.tick_ms -ne $ExpectedTickMS) {
            Add-Failure "the server ticks every $($boot.tick_ms)ms; this script expects $ExpectedTickMS"
        }
        if ([double]$boot.walk_speed -ne $ExpectedWalkSpeed) {
            Add-Failure "the server walks at $($boot.walk_speed) units/s; this script expects $ExpectedWalkSpeed"
        }
        if ([int]$boot.seeded_items -ne 1) {
            Add-Failure ("the server seeded $($boot.seeded_items) item(s); the milestone is two " +
                "clients racing for exactly one")
        }
        if ([int]$boot.inventory_size -ne $ExpectedInventorySize) {
            Add-Failure "the server's inventory holds $($boot.inventory_size) slots; this script assumes $ExpectedInventorySize"
        }
    }

    $spawns = Select-Events $events "item_spawned"
    $seedItem = -1
    if ($spawns.Count -lt 1) {
        Add-Failure "the server logged no item_spawned; nothing was ever placed in the world"
    } else {
        $seeded = $spawns[0]
        $seedItem = [int]$seeded.item
        $gap = Get-Distance ([double]$seeded.x) ([double]$seeded.z) $ItemX $ItemZ
        Write-Host ("==> server: item {0} ({1}) entered the world at ({2}, {3}) on tick {4}; it was seeded at ({5}, {6})" -f `
            $seedItem, $seeded.kind, $seeded.x, $seeded.z, $seeded.t, $ItemX, $ItemZ)
        if ($gap -gt $LogCoordinateEpsilon) {
            Add-Failure ("item_spawned put the seeded item at ($($seeded.x), $($seeded.z)) but it was " +
                "seeded at ($ItemX, $ItemZ): $([math]::Round($gap, 6)) units apart. The log is not " +
                "recording where items are.")
        }
        if ($seeded.kind -ne "acorn") {
            Add-Failure "the seeded item logged kind '$($seeded.kind)', want 'acorn'"
        }
    }

    $pickups = Select-Events $events "pickup" -1 $seedItem
    $intentTicks = @{}
    foreach ($event in $pickups) { $intentTicks[[int]$event.player] = [int]$event.t }
    Write-Host ("==> server: {0} pickup intent(s) for item {1}, from player(s) {2}" -f `
        $pickups.Count, $seedItem, (($intentTicks.Keys | Sort-Object) -join ", "))
    if ($pickups.Count -ne 2) {
        Add-Failure ("the server logged $($pickups.Count) pickup intent(s) for item $seedItem, want 2 " +
            "-- one per client")
    }
    if ($intentTicks.Keys.Count -ne 2) {
        Add-Failure ("the $($pickups.Count) pickup intent(s) for item $seedItem came from " +
            "$($intentTicks.Keys.Count) distinct player(s), want 2")
    }

    $resolved = Select-Events $events "pickup_resolved" -1 $seedItem
    $lost = Select-Events $events "pickup_lost" -1 $seedItem
    $rejected = Select-Events $events "pickup_rejected"
    $noRoom = Select-Events $events "pickup_no_room" -1 $seedItem
    $winner = -1
    $loser = -1
    $winnerSlot = -1
    if ($resolved.Count -ne 1) {
        Add-Failure ("the server resolved $($resolved.Count) pickup(s) of item $seedItem, want exactly 1. " +
            "Two clients clicked one item and the milestone is that exactly one of them gets it.")
    } else {
        $winner = [int]$resolved[0].player
        $winnerSlot = [int]$resolved[0].slot
    }
    if ($lost.Count -ne 1) {
        Add-Failure ("the server recorded $($lost.Count) lost pickup(s) of item $seedItem, want exactly 1. " +
            "The client that did not get it must be told it did not get it.")
    } else {
        $loser = [int]$lost[0].player
    }
    if ($rejected.Count -ne 0) {
        Add-Failure "the server rejected $($rejected.Count) pickup intent(s); every click here was on a live item"
    }
    if ($noRoom.Count -ne 0) {
        Add-Failure "the server refused $($noRoom.Count) pickup(s) for want of room; both inventories were empty"
    }
    if ($winner -ge 1 -and $loser -ge 1) {
        Write-Host ("==> server: player {0} took item {1} into slot {2} on tick {3}; player {4} lost it on tick {5}" -f `
            $winner, $seedItem, $winnerSlot, $resolved[0].t, $loser, $lost[0].t)
        if ($winner -eq $loser) {
            Add-Failure "player $winner both won and lost item $seedItem; that is one player, not a contest"
        }
        $contestants = @(@($winner, $loser) | Sort-Object)
        $clicked = @($intentTicks.Keys | Sort-Object)
        if (($contestants -join ",") -ne ($clicked -join ",")) {
            Add-Failure ("the contest was between players $($contestants -join ' and ') but the intents " +
                "came from $($clicked -join ' and ')")
        }
        if ($resolved[0].kind -ne "acorn") {
            Add-Failure "pickup_resolved logged kind '$($resolved[0].kind)', want 'acorn'"
        }
    }

    $playerPathEvents = Count-PlayerPathAssigned $events
    $moveToEvents = (Select-Events $events "move_to").Count
    Write-Host ("==> server: player path_assigned={0}, move_to={1} (want 0 / 0)" -f `
        $playerPathEvents, $moveToEvents)
    if ($playerPathEvents -gt 0) {
        Add-Failure "GAMELOG player path_assigned=$playerPathEvents, want 0"
    }
    if ($moveToEvents -gt 0) {
        Add-Failure ("GAMELOG move_to=$moveToEvents, want 0 -- item clicks must resolve to pickup, and " +
            "the winner's walk-away must be wish move samples")
    }

    if ($intentTicks.Keys.Count -eq 2) {
        $players = @($intentTicks.Keys | Sort-Object)
        $tickA = [int]$intentTicks[$players[0]]
        $tickB = [int]$intentTicks[$players[1]]
        Write-Host ("==> server: player {0}'s pickup intent on tick {1}, player {2}'s on tick {3}" -f `
            $players[0], $tickA, $players[1], $tickB)
        if ($tickA -ne $tickB) {
            if ($ContestAttempt -lt $MaxContestAttempts) {
                $script:splitTickRetry = $true
                $script:splitTickA = $tickA
                $script:splitTickB = $tickB
                Write-Host ("==> split pickup ticks $tickA vs $tickB on attempt " +
                    "$ContestAttempt/$MaxContestAttempts; will retry contest (same-tick assert kept)")
                throw "marque-contest-split-tick-retry"
            }
            Add-Failure ("the two pickup intents landed on different ticks, $tickA and $tickB. " +
                "Both players spawn at the origin and approach at one speed, so equal intent ticks " +
                "are what makes them reach the item together; a run that started them apart is a " +
                "sequence and its winner is whoever clicked first, not whoever the tick loop chose.")
        }
    }
    if ($resolved.Count -eq 1 -and $lost.Count -eq 1) {
        $gap = [int]$lost[0].t - [int]$resolved[0].t
        Write-Host ("==> server: the contest resolved on tick {0} and was lost on tick {1}; gap {2} tick(s)" -f `
            $resolved[0].t, $lost[0].t, $gap)
        if ($gap -ne 0) {
            Add-Failure ("the item was taken on tick $($resolved[0].t) and lost on tick $($lost[0].t), " +
                "$gap tick(s) apart. A same-tick contest is decided inside one pass of the tick loop; " +
                "this one was decided across ticks, so the two players did not reach the item together.")
        }
    }

    if ($loser -ge 1 -and $lost.Count -eq 1) {
        Write-Host ("==> server: player {0} lost on tick {1}; halt clears steer (no player path_assigned)" -f `
            $loser, $lost[0].t)
        $loserMovesAfterLoss = 0
        $lossTick = [int]$lost[0].t
        foreach ($move in (Select-Events $events "move" $loser)) {
            if ([int]$move.t -lt $lossTick) { continue }
            $dx = [double]$move.dx
            $dz = [double]$move.dz
            if ([math]::Sqrt(($dx)*($dx) + ($dz)*($dz)) -gt 1e-6) { $loserMovesAfterLoss++ }
        }
        if ($loserMovesAfterLoss -gt 0) {
            Add-Failure ("player $loser sent $loserMovesAfterLoss non-zero move wish(es) after losing on " +
                "tick $lossTick; the loser must stop, not keep steering")
        }
    }

    $dropSpawn = $null
    if ($winner -ge 1) {
        $winnerWishes = Count-NonzeroMoves $events $winner
        Write-Host ("==> server: winner player {0} logged {1} non-zero move wish(es) (walk-away)" -f `
            $winner, $winnerWishes)
        if ($winnerWishes -lt 1) {
            Add-Failure ("player $winner logged $winnerWishes non-zero move wish(es), want >= 1 -- the " +
                "winner must wish-steer away before dropping")
        }

        $drops = Select-Events $events "drop" $winner
        if ($drops.Count -ne 1) {
            Add-Failure "the server logged $($drops.Count) drop(s) by player $winner, want exactly 1"
        } else {
            $drop = $drops[0]
            if ([int]$drop.slot -ne $winnerSlot) {
                Add-Failure ("the drop emptied slot $($drop.slot) but the pickup filled slot $winnerSlot")
            }
            $droppedId = [int]$drop.item
            if ($droppedId -eq $seedItem) {
                Add-Failure ("the dropped item kept id $droppedId; a dropped item gets a fresh one " +
                    "(TestDropIsOneMove / drop_store_test.go)")
            }
            $dropSpawns = Select-Events $events "item_spawned" -1 $droppedId
            if ($dropSpawns.Count -ne 1) {
                Add-Failure "the drop logged $($dropSpawns.Count) item_spawned for item $droppedId, want 1"
            } else {
                $dropSpawn = $dropSpawns[0]
                $fromOrigin = Get-Distance ([double]$dropSpawn.x) ([double]$dropSpawn.z) 0.0 0.0
                $fromSeed = Get-Distance ([double]$dropSpawn.x) ([double]$dropSpawn.z) $ItemX $ItemZ
                Write-Host ("==> server: player {0} dropped slot {1} on tick {2}; item {3} entered the world at ({4}, {5})" -f `
                    $winner, $drop.slot, $drop.t, $droppedId, $dropSpawn.x, $dropSpawn.z)
                Write-Host ("==> server: that point is {0:N3} units from the origin and {1:N3} from where the item was seeded" -f `
                    $fromOrigin, $fromSeed)
                if ($fromOrigin -lt $MinDropDisplacement) {
                    Add-Failure ("the drop landed $([math]::Round($fromOrigin, 3)) units from the origin, " +
                        "under $MinDropDisplacement. A coordinate this close to zero cannot be told " +
                        "apart from a zeroed one, which is the exact defect this assertion exists for.")
                }
                if ($fromSeed -lt $MinDropDisplacement) {
                    Add-Failure ("the drop landed $([math]::Round($fromSeed, 3)) units from where the " +
                        "item was seeded, under $MinDropDisplacement; the winner did not walk anywhere " +
                        "before dropping and the coordinates prove nothing")
                }
            }
        }
    }
    $allSpawns = Select-Events $events "item_spawned"
    if ($allSpawns.Count -ne 2) {
        Add-Failure ("the server logged $($allSpawns.Count) item_spawned event(s), want exactly 2: the " +
            "seed and the drop")
    }

    $winnerLabel = "player $winner"
    if ($winner -lt 1) { $winnerLabel = "nobody -- the contest resolved to no single winner" }

    foreach ($client in $running) {
        $label = $client.Label
        $report = $client.Report
        if ($report.Joined -lt 1) { continue }
        $won = $report.Joined -eq $winner

        if ($null -eq $report.SeedItem) {
            Add-Failure "client $label never reported the item it found on the ground"
        } elseif ($seedItem -ge 1) {
            $seen = $report.SeedItem
            if ($seen.Id -ne $seedItem) {
                Add-Failure "client $label found item $($seen.Id) on the ground; the server seeded $seedItem"
            }
            $gap = Get-Distance $seen.X $seen.Z $ItemX $ItemZ
            if ($gap -gt $MaxLayerDisagreement) {
                Add-Failure ("client $label drew the seeded item at ($($seen.X), $($seen.Z)); the server " +
                    "put it at ($ItemX, $ItemZ), $([math]::Round($gap, 3)) units away")
            }
        }

        $expectedItems = @{ 1 = 1; 2 = 0; 3 = 1 }
        $expectedCarried = @{ 1 = 0; 2 = $(if ($won) { 1 } else { 0 }); 3 = 0 }
        foreach ($index in 1, 2, 3) {
            if (-not $report.ItemCounts.ContainsKey($index)) {
                Add-Failure "client $label reported no item count for shot $index"
            } elseif ($report.ItemCounts[$index] -ne $expectedItems[$index]) {
                Add-Failure ("client $label drew $($report.ItemCounts[$index]) item body/bodies in shot " +
                    "$index, want $($expectedItems[$index])")
            }
            if (-not $report.Inventory.ContainsKey($index)) {
                Add-Failure "client $label reported no inventory for shot $index"
                continue
            }
            $inv = $report.Inventory[$index]
            if ($inv.Occupied -ne $expectedCarried[$index]) {
                Add-Failure ("client $label held $($inv.Occupied) item(s) in shot $index, want " +
                    "$($expectedCarried[$index]); it joined as player $($report.Joined) and the server " +
                    "gave the item to $winnerLabel")
            }
            if ($inv.Size -ne $ExpectedInventorySize) {
                Add-Failure "client $label drew $($inv.Size) inventory slot(s) in shot $index, want $ExpectedInventorySize"
            }
        }
        if ($won -and $winnerSlot -ge 0) {
            $carried = $null
            if ($report.Slots.ContainsKey(2)) { $carried = $report.Slots[2] }
            if ($null -eq $carried -or -not $carried.ContainsKey($winnerSlot)) {
                Add-Failure ("client $label won item $seedItem into slot $winnerSlot but drew nothing " +
                    "in that slot")
            } elseif ($carried[$winnerSlot] -ne "acorn") {
                Add-Failure "client $label drew '$($carried[$winnerSlot])' in slot $winnerSlot, want 'acorn'"
            } else {
                Write-Host "==> client $label (player $($report.Joined)) drew an acorn in slot $winnerSlot after the contest"
            }
            if ($null -eq $report.Wish) {
                Add-Failure "client $label won but never reported DEMO wish for the walk-away"
            } elseif ([math]::Sqrt(([double]$report.Wish[0])*([double]$report.Wish[0]) + ([double]$report.Wish[1])*([double]$report.Wish[1])) -lt 1e-6) {
                Add-Failure "client $label's DEMO wish was zero; the walk-away must steer"
            }
            if ($null -eq $report.WalkAwayArrived) {
                Add-Failure "client $label won but never reported DEMO walkaway_arrived"
            } elseif ($null -ne $dropSpawn) {
                $gap = Get-Distance ([double]$report.WalkAwayArrived[0]) ([double]$report.WalkAwayArrived[1]) `
                    ([double]$dropSpawn.x) ([double]$dropSpawn.z)
                Write-Host ("==> client {0} walkaway_arrived is {1:N4} units from the drop spawn" -f `
                    $label, $gap)
                if ($gap -gt $MaxWalkAwayDropDisagreement) {
                    Add-Failure ("client $label stood at ($($report.WalkAwayArrived[0]), $($report.WalkAwayArrived[1])) " +
                        "after wish steer but item_spawned the drop at ($($dropSpawn.x), $($dropSpawn.z)): " +
                        "$([math]::Round($gap, 3)) units apart (limit $MaxWalkAwayDropDisagreement)")
                }
            }
        }
        if ($report.Outcome -lt 0) {
            Add-Failure "client $label never reported whether it won"
        } elseif (($report.Outcome -eq 1) -ne $won) {
            Add-Failure ("client $label reported outcome $($report.Outcome) but the server gave the item " +
                "to $winnerLabel and this client is player $($report.Joined)")
        }
    }

    if ($null -ne $dropSpawn) {
        $droppedId = [int]$dropSpawn.item
        foreach ($client in $running) {
            $report = $client.Report
            if (-not $report.Items.ContainsKey(3)) { continue }
            if (-not $report.Items[3].ContainsKey($droppedId)) {
                Add-Failure ("client $($client.Label) did not draw the dropped item $droppedId in shot 3; " +
                    "it drew $(($report.Items[3].Keys | Sort-Object) -join ', ')")
                continue
            }
            $drawn = $report.Items[3][$droppedId]
            $gap = Get-Distance $drawn.X $drawn.Z ([double]$dropSpawn.x) ([double]$dropSpawn.z)
            Write-Host ("==> client {0} drew the dropped item {1:N4} units from where the server says it landed" -f `
                $client.Label, $gap)
            if ($gap -gt $MaxLayerDisagreement) {
                Add-Failure ("client $($client.Label) drew item $droppedId at ($($drawn.X), $($drawn.Z)) in " +
                    "shot 3, but the server logged it spawning at ($($dropSpawn.x), $($dropSpawn.z)): " +
                    "$([math]::Round($gap, 3)) units apart")
            }
            if ($drawn.Kind -ne "acorn") {
                Add-Failure "client $($client.Label) drew the dropped item as '$($drawn.Kind)', want 'acorn'"
            }
        }
    }
} catch {
    if ($script:splitTickRetry -and $_.Exception.Message -eq "marque-contest-split-tick-retry") {
        # Expected early exit so the harness can re-run; do not record as a failure.
    } else {
        Add-Failure "$($_.Exception.Message) [$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())]"
    }
} finally {
    if ($null -ne $server) {
        if ($server.HasExited) {
            if (-not $script:splitTickRetry) {
                Add-Failure "marqued exited on its own with code $($server.ExitCode); it must outlive the clients"
            }
        } else {
            Write-Host "==> stopping marqued (pid $($server.Id))"
            Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
            $server.WaitForExit(5000) | Out-Null
        }
    }
    if (-not $script:splitTickRetry -and (Test-Path $serverErr)) {
        $stderrText = Get-Content -Path $serverErr -Raw
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            $firstLine = $stderrText.Trim() -split "`r?`n" | Select-Object -First 1
            Add-Failure "marqued wrote to stderr: $firstLine"
        }
    }
    Show-File "marqued event log ($serverOut)" $serverOut
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($splitTickRetry) {
    Write-Host ""
    Write-Host ("==> GAMELOG split ticks $splitTickA vs $splitTickB; re-running contest " +
        "attempt $($ContestAttempt + 1)/$MaxContestAttempts")
    $env:MARQUE_CONTEST_ATTEMPT = [string]($ContestAttempt + 1)
    $forward = @()
    foreach ($key in $PSBoundParameters.Keys) {
        $forward += @("-$key", $PSBoundParameters[$key])
    }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @forward
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "evidence (screenshots, client logs, server event log): $OutDir"
if ($failures.Count -eq 0) {
    Write-Host "CONTESTED PICKUP DEMO OK"
    exit 0
}
Write-Host "CONTESTED PICKUP DEMO FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1
