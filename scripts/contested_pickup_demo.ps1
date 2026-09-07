[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-contested-pickup"),
    [double] $ItemX = -5.0,
    [double] $ItemZ = -5.0,
    [string] $DropClick = "0.30,0.62",
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 150
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ExpectedTickMS = 150
$ExpectedWalkSpeed = 3.0
$ExpectedInventorySize = 28

$LogCoordinateEpsilon = 1e-6

$MaxLayerDisagreement = 0.05

$MinDropDisplacement = 2.0

$MaxWalkTickError = 2

$MaxAimTickSkew = 1

$ExpectedPickupRange = 0.5

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-pickup-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
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

function Get-Distance([double] $ax, [double] $az, [double] $bx, [double] $bz) {
    return [math]::Sqrt([math]::Pow($ax - $bx, 2) + [math]::Pow($az - $bz, 2))
}


function Read-ClientReport([string] $path) {
    $report = @{
        Joined = -1
        Failures = New-Object System.Collections.Generic.List[string]
        Done = $false
        SyncTick = -1
        ClickTick = -1
        Outcome = -1
        SeedItem = $null
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
                $report.ClickTick = [int]$Matches[2]
            }
            '^DEMO outcome (\d+)\s*$' { $report.Outcome = [int]$Matches[1] }
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

function Get-PathSpan($path) {
    $from = $path.points[0]
    $to = $path.points[$path.points.Count - 1]
    return Get-Distance ([double]$from[0]) ([double]$from[1]) ([double]$to[0]) ([double]$to[1])
}

function Test-Walk($events, [int] $player, $path, [string] $label, [double] $perTick) {
    $to = $path.points[$path.points.Count - 1]
    $span = Get-PathSpan $path
    $arrived = $null
    foreach ($candidate in (Select-Events $events "arrived" $player)) {
        if ([int]$candidate.t -le [int]$path.start_tick) { continue }
        if ((Get-Distance ([double]$candidate.x) ([double]$candidate.z) `
                ([double]$to[0]) ([double]$to[1])) -gt $LogCoordinateEpsilon) { continue }
        $arrived = $candidate
        break
    }
    if ($null -eq $arrived) {
        $seen = (Select-Events $events "arrived" $player).Count
        Add-Failure ("${label}: the server never recorded player $player arriving at " +
            "($([math]::Round([double]$to[0], 3)), $([math]::Round([double]$to[1], 3))), the endpoint " +
            "of the path it assigned at tick $($path.start_tick); the whole log holds $seen arrived " +
            "event(s) for that player. The clients walked the polyline they were handed, but the " +
            "server's world never moved.")
        return $null
    }

    $took = [int]$arrived.t - [int]$path.start_tick
    $expected = [int][math]::Ceiling($span / $perTick)
    Write-Host ("==> server: {0} -- player {1} walked {2:N3} units in {3} tick(s), from tick {4} to {5}; walking that far takes {6}" -f `
        $label, $player, $span, $took, $path.start_tick, $arrived.t, $expected)
    if ([math]::Abs($took - $expected) -gt $MaxWalkTickError) {
        Add-Failure ("${label}: player $player crossed $([math]::Round($span, 3)) units in $took tick(s), " +
            "but at $ExpectedWalkSpeed units per second on ${ExpectedTickMS}ms ticks that walk takes " +
            "$expected. The server's world did not walk the path, it jumped it.")
    }
    return $arrived
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

    $clickTicks = @($running | ForEach-Object { $_.Report.ClickTick })
    Write-Host ("==> clients chose click ticks {0} and {1} (sync ticks {2} and {3})" -f `
        $clickTicks[0], $clickTicks[1], $running[0].Report.SyncTick, $running[1].Report.SyncTick)
    if ($clickTicks[0] -lt 0 -or $clickTicks[1] -lt 0) {
        Add-Failure "a client never reported the tick it chose to click on"
    } elseif ([math]::Abs($clickTicks[0] - $clickTicks[1]) -gt $MaxAimTickSkew) {
        Add-Failure ("the two clients aimed at server ticks $($clickTicks[0]) and " +
            "$($clickTicks[1]), $([math]::Abs($clickTicks[0] - $clickTicks[1])) apart. Anchoring " +
            "alone separates two clocks by at most one tick, so they disagree about more than " +
            "which side of a tick boundary they are on and neither one's aim can be trusted.")
    }

    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) {
        Add-Failure ("the server wrote no GAMELOG events to $serverOut; this run contains no " +
            "server-side evidence at all")
    }

    $perTick = $ExpectedWalkSpeed * $ExpectedTickMS / 1000.0
    $started = Select-Events $events "server_started"
    if ($started.Count -ne 1) {
        Add-Failure "the log holds $($started.Count) server_started event(s), want 1"
    } else {
        $boot = $started[0]
        if ([int]$boot.tick_ms -ne $ExpectedTickMS) {
            Add-Failure "the server ticks every $($boot.tick_ms)ms; this script's spans assume $ExpectedTickMS"
        }
        if ([double]$boot.walk_speed -ne $ExpectedWalkSpeed) {
            Add-Failure "the server walks at $($boot.walk_speed) units/s; this script's spans assume $ExpectedWalkSpeed"
        }
        if ([int]$boot.seeded_items -ne 1) {
            Add-Failure ("the server seeded $($boot.seeded_items) item(s); the milestone is two " +
                "clients racing for exactly one")
        }
        if ([int]$boot.inventory_size -ne $ExpectedInventorySize) {
            Add-Failure "the server's inventory holds $($boot.inventory_size) slots; this script assumes $ExpectedInventorySize"
        }
        $perTick = [double]$boot.walk_speed * [int]$boot.tick_ms / 1000.0
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

    $contestPaths = @{}
    foreach ($player in $intentTicks.Keys) {
        $tick = $intentTicks[$player]
        $match = $null
        foreach ($path in (Select-Events $events "path_assigned" $player)) {
            if ([int]$path.t -ne $tick) { continue }
            $match = $path
            break
        }
        if ($null -eq $match) {
            Add-Failure ("player $player's pickup at tick $tick assigned no path; there was nothing " +
                "for that client to walk")
            continue
        }
        if ($match.points.Count -lt 2) {
            Add-Failure "player $player's contested path carries $($match.points.Count) point(s); a walk needs two"
            continue
        }
        $to = $match.points[$match.points.Count - 1]
        if ($seedItem -ge 1) {
            $miss = Get-Distance ([double]$to[0]) ([double]$to[1]) $ItemX $ItemZ
            if ($miss -gt $LogCoordinateEpsilon) {
                Add-Failure ("player $player's contested path ends at ($($to[0]), $($to[1])), not at the " +
                    "item's ($ItemX, $ItemZ); that walk was not a walk to the item")
            }
        }
        $contestPaths[$player] = $match
    }
    if ($contestPaths.Keys.Count -eq 2) {
        $players = @($contestPaths.Keys | Sort-Object)
        $first = $contestPaths[$players[0]]
        $second = $contestPaths[$players[1]]
        $spanGap = [math]::Abs((Get-PathSpan $first) - (Get-PathSpan $second))
        Write-Host ("==> server: player {0}'s path was assigned on tick {1} ({2:N3} units), player {3}'s on tick {4} ({5:N3} units)" -f `
            $players[0], $first.start_tick, (Get-PathSpan $first), $players[1], $second.start_tick, (Get-PathSpan $second))
        if ([int]$first.start_tick -ne [int]$second.start_tick) {
            Add-Failure ("the two walks to the item started on different ticks, $($first.start_tick) and " +
                "$($second.start_tick). Both players spawn at the origin and walk at one speed, so equal " +
                "start ticks are what makes them reach the item together; a run that started them apart " +
                "is a sequence and its winner is whoever clicked first, not whoever the tick loop chose.")
        }
        if ($spanGap -gt $LogCoordinateEpsilon) {
            Add-Failure ("the two walks to the item span $([math]::Round($spanGap, 6)) units differently; " +
                "the two players were not equidistant from it")
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

    if ($loser -ge 1 -and $lost.Count -eq 1 -and $seedItem -ge 1) {
        $lossTick = [int]$lost[0].t
        $halts = New-Object System.Collections.Generic.List[object]
        foreach ($candidate in (Select-Events $events "path_assigned" $loser)) {
            if ([int]$candidate.t -ne $lossTick) { continue }
            $halts.Add($candidate)
        }
        if ($halts.Count -ne 1) {
            Add-Failure ("the server assigned player $loser $($halts.Count) path(s) on tick $lossTick, " +
                "want exactly 1 -- the halt losePickup sends. Without it the run holds no record of " +
                "where the loser was when it lost.")
        } elseif ($halts[0].points.Count -ne 1) {
            Add-Failure ("player $loser's halt on tick $lossTick carries $($halts[0].points.Count) " +
                "point(s); a halt is one point, and that point is where the loser stopped")
        } else {
            $stopped = $halts[0].points[0]
            $reach = Get-Distance ([double]$stopped[0]) ([double]$stopped[1]) $ItemX $ItemZ
            Write-Host ("==> server: player {0} halted at ({1}, {2}) on tick {3}, {4:N3} units from item {5}; PickupRange is {6}" -f `
                $loser, $stopped[0], $stopped[1], $lossTick, $reach, $seedItem, $ExpectedPickupRange)
            if ($reach -gt $ExpectedPickupRange) {
                Add-Failure ("player $loser was condemned at ($($stopped[0]), $($stopped[1])), " +
                    "$([math]::Round($reach, 3)) units from item $seedItem and outside the " +
                    "$ExpectedPickupRange-unit PickupRange. It lost a contest for an item it was " +
                    "standing too far away to have taken.")
            }
        }
    }

    if ($winner -ge 1 -and $contestPaths.ContainsKey($winner)) {
        $null = Test-Walk $events $winner $contestPaths[$winner] "the walk to the item" $perTick
    }

    $moves = Select-Events $events "move_to"
    Write-Host "==> server: $($moves.Count) move_to intent(s) in the whole run"
    if ($moves.Count -ne 1) {
        Add-Failure ("the server logged $($moves.Count) move_to intent(s), want exactly 1 -- the " +
            "winner's walk away before dropping. Both clicks on the item must have resolved to the " +
            "item and not to the ground beneath it.")
    }
    $dropSpawn = $null
    if ($moves.Count -eq 1 -and $winner -ge 1) {
        if ([int]$moves[0].player -ne $winner) {
            Add-Failure ("the only move_to came from player $($moves[0].player) but player $winner won " +
                "the item; the client that walked away is not the one that had something to drop")
        }
        $awayPath = $null
        foreach ($path in (Select-Events $events "path_assigned" ([int]$moves[0].player))) {
            if ([int]$path.t -ne [int]$moves[0].t) { continue }
            $awayPath = $path
            break
        }
        if ($null -eq $awayPath) {
            Add-Failure "the winner's move_to at tick $($moves[0].t) assigned no path"
        } else {
            $arrived = Test-Walk $events $winner $awayPath "the walk away" $perTick
            $drops = Select-Events $events "drop" $winner
            if ($drops.Count -ne 1) {
                Add-Failure "the server logged $($drops.Count) drop(s) by player $winner, want exactly 1"
            } elseif ($null -ne $arrived) {
                $drop = $drops[0]
                if ([int]$drop.t -lt [int]$arrived.t) {
                    Add-Failure ("player $winner dropped on tick $($drop.t) but did not arrive until " +
                        "tick $($arrived.t); the item landed under a walker, so its coordinates say " +
                        "nothing about a destination")
                }
                if ([int]$drop.slot -ne $winnerSlot) {
                    Add-Failure ("the drop emptied slot $($drop.slot) but the pickup filled slot $winnerSlot")
                }
                $droppedId = [int]$drop.item
                if ($droppedId -eq $seedItem) {
                    Add-Failure ("the dropped item kept id $droppedId; a dropped item gets a fresh one " +
                        "(PROTOCOL.md, Drop)")
                }
                $dropSpawns = Select-Events $events "item_spawned" -1 $droppedId
                if ($dropSpawns.Count -ne 1) {
                    Add-Failure "the drop logged $($dropSpawns.Count) item_spawned for item $droppedId, want 1"
                } else {
                    $dropSpawn = $dropSpawns[0]
                    $stoodGap = Get-Distance ([double]$dropSpawn.x) ([double]$dropSpawn.z) `
                        ([double]$arrived.x) ([double]$arrived.z)
                    $fromOrigin = Get-Distance ([double]$dropSpawn.x) ([double]$dropSpawn.z) 0.0 0.0
                    $fromSeed = Get-Distance ([double]$dropSpawn.x) ([double]$dropSpawn.z) $ItemX $ItemZ
                    Write-Host ("==> server: player {0} dropped slot {1} on tick {2}; item {3} entered the world at ({4}, {5}), where that player arrived on tick {6}" -f `
                        $winner, $drop.slot, $drop.t, $droppedId, $dropSpawn.x, $dropSpawn.z, $arrived.t)
                    Write-Host ("==> server: that point is {0:N3} units from the origin and {1:N3} from where the item was seeded" -f `
                        $fromOrigin, $fromSeed)
                    if ($stoodGap -gt $LogCoordinateEpsilon) {
                        Add-Failure ("item_spawned put the dropped item at ($($dropSpawn.x), $($dropSpawn.z)) " +
                            "but its dropper had arrived at ($($arrived.x), $($arrived.z)): " +
                            "$([math]::Round($stoodGap, 6)) units apart. The log is not recording where " +
                            "dropped items land.")
                    }
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
    Add-Failure "$($_.Exception.Message) [$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())]"
} finally {
    if ($null -ne $server) {
        if ($server.HasExited) {
            Add-Failure "marqued exited on its own with code $($server.ExitCode); it must outlive the clients"
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

Write-Host ""
Write-Host "evidence (screenshots, client logs, server event log): $OutDir"
if ($failures.Count -eq 0) {
    Write-Host "CONTESTED PICKUP DEMO OK"
    exit 0
}
Write-Host "CONTESTED PICKUP DEMO FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1
