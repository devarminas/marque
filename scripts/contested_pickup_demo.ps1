<#
.SYNOPSIS
    The M1 milestone, on screen and in the server's own ledger: two real
    windowed clients on one real server click the same ground item on the same
    tick, exactly one of them gets it, and the winner then walks somewhere it
    chose and drops it. Exits 0 only if the server's event log says exactly one
    pickup resolved and exactly one was lost, both clients saw the item leave
    the world and come back, and every coordinate and every tick span in the
    run is plausible.

.DESCRIPTION
    `scripts/two_client_demo.ps1` is the M0 milestone and this is M1's; the two
    do not overlap and neither replaces the other. That one choreographs ground
    clicks so that exactly one player moves per capture window, because its
    claim ("each client sees the other walk") needs a still camera as a control.
    This one is the opposite scenario by construction: both players click the
    same thing at the same moment, and there is no still camera in it anywhere.

    What it generalises from that script is the thing that script was corrected
    into being: **the claim lives on the server, and only the server's event log
    can carry it.** "Exactly one client gets the item" is a purely server-side
    fact. No arrangement of pixels can establish it, because two clients that
    both drew an empty patch of ground would look identical whether the server
    gave the item to one player, to both, or to neither.

    Three evidence layers, and the milestone needs all three.

    Layer one, the server (`Test-ServerLayer`). Exactly one `pickup_resolved`
    for the seeded item and exactly one `pickup_lost`, naming different players
    and between them naming both; two `pickup` intents, one per player; no
    `pickup_rejected` and no `pickup_no_room`. This is the milestone sentence,
    and nothing else in this file can substitute for it.

    Layer two, the clients (`Test-ClientLayer`). Both clients must be shown to
    have *seen* the outcome, because "by observation" is what the milestone
    says. Each reports every item body and every inventory slot it drew at each
    of three captures: the item present in both worlds and both inventories
    empty; the item gone from both worlds and exactly one inventory holding it;
    the item back on the ground in both worlds and the inventory empty again. A
    client removes an item body only in response to the server's `item_despawn`
    frame, so the middle capture is this run's evidence that the despawn
    reached both clients -- see the note on `item_despawn` under KNOWN GAPS.

    Layer three, the two tied together (`Test-LayerAgreement`). The client whose
    inventory filled must be the player the server's log names as the winner,
    and the position both clients draw the dropped item at must be the position
    the server logged it spawning at.

    Two false passes this family already has, both found by verifiers on the M0
    demo, and how this script avoids each:

    - **A frozen server passes a client-only check.** A tick loop that assigns
      and broadcasts paths and never advances anybody still produces moving
      pixels on every screen, because clients interpolate the polylines they
      are handed. It cannot produce this run's `pickup_resolved`, which is
      emitted only after movement has carried a player inside `PickupRange`,
      and it cannot produce either `arrived`.

    - **A teleporting server passes the M0 demo.** With the tick loop's
      per-tick distance raised to 1000.0 the world crosses a whole path in one
      tick and emits a perfectly formed `arrived`; nothing in that demo asserts
      the span between assignment and arrival is plausible. Every walk here is
      checked against `span / (WalkSpeed * TickDuration)`, so a walk that took
      one tick fails whatever the endpoints say. That closes the open half of
      unit M1j at the layer that depends on it.

    A third, this script's own: **a stale PNG satisfies a `Test-Path` plus size
    check.** The output directory is emptied at startup, and a directory this
    script did not write is refused rather than emptied.

.NOTES
    KNOWN GAPS, stated here because the assertions below are shaped around them.

    - **There is no `item_despawn` event in the server's event log.** The
      despawn is a wire message (`items.go`, `w.broadcast(mnet.ItemDespawn...)`)
      and `EvItemDespawned` does not exist. So the despawn is proven on the
      client layer -- both clients drop the body, which they do only on
      receiving that frame -- and on the server layer by `pickup_resolved`,
      which is the event that causes it. Adding the event is a follow-up.

    - **The winner is decided by join order** (`world.go`, `step`): the first
      player in `w.order` with a pending pickup and in range takes it, and every
      later player in that same pass finds it gone. This script asserts that
      exactly one won, never which one; which one is a consequence of who
      connected first and is not part of the claim.

.PARAMETER Godot
    The Godot 4 executable. Defaults to $env:GODOT, then "godot" on PATH.

.PARAMETER OutDir
    The evidence directory: the six PNGs, both clients' stdout and stderr, and
    the server's event log and stderr. Never deleted at teardown -- the GAMELOG
    in it is the only server-side proof this run produces -- and emptied at the
    start of the next run.

.PARAMETER ItemX
.PARAMETER ItemZ
    Where the one seeded item lies. Both players spawn at the origin and walk at
    one speed, so any position makes them equidistant; this one is chosen to
    draw in the upper-left of the viewport, well clear of the inventory panel,
    which is opaque (unit M1k) and would swallow a click aimed at an item drawn
    underneath it. The client checks the item's screen position against the
    panel's rect and fails rather than trusting this default.

.PARAMETER DropClick
    Where the winner clicks the ground before dropping, as a viewport fraction.
    Must resolve to ground somewhere the winner is not already standing: the
    whole point of the drop is that its logged coordinates are checked against a
    place the dropper deliberately walked to.
#>
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

# ---------------------------------------------------------------------------
# The server's own constants, restated. Every one of them is read back out of
# the run's `server_started` line rather than trusted from here; these are the
# expected values, and a mismatch is a failure rather than a silent recalibration
# against whatever the binary happened to be built with.
# ---------------------------------------------------------------------------
$ExpectedTickMS = 150
$ExpectedWalkSpeed = 3.0
$ExpectedInventorySize = 28

# How far a coordinate logged by the server may sit from another coordinate
# logged by the same server before the two count as different places. Both sides
# of every such pair are the same float64 printed twice, so this is slack for
# JSON round-tripping and nothing else.
$LogCoordinateEpsilon = 1e-6

# How far the server's world may sit from what a client drew, in world units.
# The item is placed where the server said and never moves, so this is slack for
# float printing rather than for a real discrepancy.
$MaxLayerDisagreement = 0.05

# How far the drop has to land from the origin and from where the item was
# picked up, in world units, before its coordinates count as evidence.
#
# This is the assertion this unit exists to add. Nothing in this repository has
# ever checked `item_spawned`'s x or z, for drops or for seeds, and a verifier
# logged zeroed coordinates while the store and the wire stayed truthful and all
# 93 Go tests stayed green. A drop whose logged position is (0, 0) or is the
# item's old resting place is indistinguishable from a bug that lost it.
$MinDropDisplacement = 2.0

# How far off the ideal a walk's duration may be, in ticks, before the tick loop
# counts as implausible. A walk of `span` units takes `ceil(span / (WalkSpeed *
# TickDuration))` ticks exactly, in a healthy run, every time; the tolerance is
# for a path assigned on a tick boundary, not for a server that crossed the
# world in one step. `distance := 1000.0` produces one tick against an expected
# sixteen and fails by a mile.
$MaxWalkTickError = 2

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

# Scratch, deleted at teardown: the built binary and the warm-up logs. Every
# observable goes to $OutDir instead.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-pickup-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
# Presence marks a directory as this script's to empty.
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

# ---------------------------------------------------------------------------
# Reading a client's stdout.
#
# The client prints and this script judges. Nothing below infers anything the
# client did not say: a capture that drew no item bodies is a `DEMO items N 0`
# line, not the absence of `DEMO item` lines, so a print loop that broke is
# distinguishable from a world that legitimately held nothing.
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Reading the server's NDJSON event log. One object per "GAMELOG "-prefixed
# line; anything else on that stream is runtime noise.
# ---------------------------------------------------------------------------

function Read-GameLog([string] $path) {
    $events = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $path)) { return , $events }
    foreach ($line in Get-Content -Path $path) {
        if (-not $line.StartsWith("GAMELOG ")) { continue }
        $events.Add(($line.Substring(8) | ConvertFrom-Json))
    }
    # Comma: a List of one would otherwise unroll to that one element.
    return , $events
}

function Test-HasField($event, [string] $name) {
    return $event.PSObject.Properties.Name -contains $name
}

# Every event of one kind, oldest first, optionally filtered to one player
# and/or one item. -1 means "any".
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

# One walk, checked for plausibility as well as for completion.
#
# The M0 demo asserts that a player arrived at the endpoint of the path it was
# assigned, which a server that crosses the whole polyline in a single tick
# satisfies perfectly. This asserts the walk *took as long as walking takes*:
# `ceil(span / (WalkSpeed * TickDuration))` ticks, within a couple. It is the
# one assertion in this file that a teleporting tick loop cannot pass.
#
# Returns the matching `arrived` event, or $null having recorded the failure.
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

# ---------------------------------------------------------------------------

try {
    # A stale PNG satisfies every check this script makes on a frame (it exists,
    # it is over 4KB), and the default -OutDir is a fixed path reused forever.
    # That is the exposure, and this is the only thing that closes it.
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
    # Built outside the repository: server/ is not this unit's to write to.
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

    # Both clients run identical arguments. Nothing distinguishes them and
    # nothing may: the whole claim is that two indistinguishable clients doing
    # the same thing at the same moment get different answers from the server.
    # Only the window position and the output paths differ.
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
        # Touching Handle caches it. Without it a -PassThru process object reads
        # its ExitCode back as empty once the process is gone, which compares
        # unequal to 0 and fails a healthy run.
        $null = $process.Handle
        $running += @{
            Label = $spec.Label; Process = $process; Stdout = $stdout
            Prefix = $prefix; Report = $null
        }
    }

    foreach ($client in $running) {
        if ($client.Process.WaitForExit($ClientTimeoutSeconds * 1000)) {
            # The parameterless overload as well: on a -PassThru process the
            # timed overload returns without caching ExitCode, which then reads
            # back empty and compares unequal to everything.
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

    # ------------------------------------------------------------------
    # Structure. Nothing behavioural yet: this is only "both clients ran".
    # ------------------------------------------------------------------
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
        # The exit code alone would let a client that quit early past: this is
        # printed only after every capture was written and the hold elapsed.
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

    # The synchronisation, checked before anything that depends on it. Two
    # clients that picked different moments to click did not run a contest, and
    # that is a different failure from a server that failed to resolve one.
    $clickTicks = @($running | ForEach-Object { $_.Report.ClickTick })
    Write-Host ("==> clients chose click ticks {0} and {1} (sync ticks {2} and {3})" -f `
        $clickTicks[0], $clickTicks[1], $running[0].Report.SyncTick, $running[1].Report.SyncTick)
    if ($clickTicks[0] -lt 0 -or $clickTicks[1] -lt 0) {
        Add-Failure "a client never reported the tick it chose to click on"
    } elseif ($clickTicks[0] -ne $clickTicks[1]) {
        Add-Failure ("the two clients aimed at different server ticks, $($clickTicks[0]) and " +
            "$($clickTicks[1]); they did not contest the item and this run says nothing about " +
            "what the server does when they do")
    }

    # ------------------------------------------------------------------
    # Layer one: what the server believes. The milestone sentence lives here
    # and nowhere else. "Exactly one client gets the item" is a purely
    # server-side fact; every pixel in this run is compatible with the server
    # having given it to both, to neither, or to somebody who is not playing.
    # ------------------------------------------------------------------
    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) {
        # Without this, every assertion below passes over an empty set.
        Add-Failure ("the server wrote no GAMELOG events to $serverOut; this run contains no " +
            "server-side evidence at all")
    }

    # The run's own constants, read back rather than assumed. A binary built
    # with a different tick or a different walk speed would make every span
    # below meaningless, and would do it silently.
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

    # The seed's coordinates. Nothing in this repository has ever asserted
    # item_spawned's x or z, and a verifier logged them zeroed while the store
    # and the wire stayed truthful and every Go test stayed green. This is the
    # seed half of that gap; the drop below is the other half.
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

    # Two intents, one per player. Both clients clicked the item body, so a run
    # in which either click was classified as a click on the *ground* under the
    # item shows up here as a missing pickup and, below, as a stray move_to.
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

    # The contest, and this is the milestone. One winner, one loser, different
    # players, and no third outcome.
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

    # ------------------------------------------------------------------
    # A same-tick race, not a sequence.
    #
    # Both players spawn at the origin and walk at one speed, so two players
    # clicking one item are equidistant and enter PickupRange together -- but
    # only if their paths were assigned on the same tick. That is the number
    # that decides whether this run was a dead heat or a queue, and it is
    # printed whether or not it holds.
    # ------------------------------------------------------------------
    $contestPaths = @{}
    foreach ($player in $intentTicks.Keys) {
        $tick = $intentTicks[$player]
        $match = $null
        foreach ($path in (Select-Events $events "path_assigned" $player)) {
            # Assigned inside the same handler as the intent, so the same tick,
            # never a later one: a later path is the halt the loser is sent.
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

    # The winner's walk, checked for plausibility as well as for completion.
    # This is what a teleporting tick loop fails.
    if ($winner -ge 1 -and $contestPaths.ContainsKey($winner)) {
        $null = Test-Walk $events $winner $contestPaths[$winner] "the walk to the item" $perTick
    }

    # ------------------------------------------------------------------
    # The drop, and the coordinate gap it closes.
    #
    # The winner walked somewhere it chose and dropped the item there. Nothing
    # in this repository has ever asserted item_spawned's x or z, so this is
    # where the log's account of where an item is gets checked against an
    # independent account of where its dropper stood.
    # ------------------------------------------------------------------
    $moves = Select-Events $events "move_to"
    Write-Host "==> server: $($moves.Count) move_to intent(s) in the whole run"
    if ($moves.Count -ne 1) {
        # Two item clicks and one ground click. A second move_to means a click
        # meant for the item resolved to the ground under it, which is the
        # picker's one-ray rule failing live.
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
                # Strictly before, not "before or on". Arriving and dropping in
                # the same tick is the ordinary case and the correct one: the
                # tick loop steps movement and then drains intents, so a drop
                # handled in the arrival tick uses the arrival position. This
                # measured 83 and 83 on a healthy run with the coordinates
                # matching exactly. What would be wrong is a drop on an *earlier*
                # tick, which lands the item under a walker somewhere along the
                # path, and the coordinate check below is what actually catches
                # it; this only says so in the reader's language.
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
                    # The assertion above is satisfied by a server that zeroed
                    # both numbers, if the walk also ended at the origin. These
                    # two are what make it evidence.
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

    # ------------------------------------------------------------------
    # Layer two: what each client saw. "By observation" is what the milestone
    # says, and a server-side ledger nobody was shown is not an observation.
    #
    # A client removes an item body only on receiving item_despawn and fills a
    # slot only on receiving inventory, so these three captures are this run's
    # proof that both frames reached both clients.
    # ------------------------------------------------------------------
    # $winner is -1 when the contest did not resolve to one player, which is
    # exactly the sabotage this script exists to catch. Every message below then
    # has to say that rather than print the sentinel, or a reader chasing a real
    # failure spends their time wondering who player -1 is.
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

        # Shot 1: one item on the ground, nothing carried, in both worlds.
        # Shot 2: no item anywhere, and exactly the winner carrying one.
        # Shot 3: one item on the ground again, nothing carried.
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

    # ------------------------------------------------------------------
    # Layer three: the two tied together. Displacement and a ledger each say
    # something happened; this says they are describing the same thing.
    # ------------------------------------------------------------------
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
            # A server that died after the last frame the clients awaited would
            # otherwise be reported as a clean run.
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
    # Scratch only: the built binary. Every observable is in $OutDir and stays
    # there, because the GAMELOG this run's server-side assertions read is the
    # only copy of the server's account of it.
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
