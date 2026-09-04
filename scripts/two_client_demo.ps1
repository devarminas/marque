<#
.SYNOPSIS
    The M0 milestone, on screen and in both directions: two real windowed
    clients on one real server, each clicking the ground in turn while the other
    watches. Each client screenshots itself four times. Exits 0 only if each
    client saw two bodies in every frame, saw *the other* player move, and the
    server's own event log says it moved them.

.DESCRIPTION
    This is the visual half of M0e. `scripts/interop_test.ps1` proves the same
    thing headless and in far more detail; this one exists because a headless
    run cannot show a capsule, a cast shadow, or the fact that the two clients
    are drawing the same world. NOTES.md says the game screenshots itself and
    the desktop is not automated, so the click is a synthesised input event
    inside the client rather than a driven mouse, and the capture is the
    client's own viewport.

    The run is two phases, one per client, and the phases are why it is
    structured this way rather than having both walk at once:

    - Phase 1: client a clicks and walks, client b stands still.
    - Phase 2: client b clicks and walks, client a stands still.

    "Each sees the other walk" needs both directions, and each direction needs a
    control. A client that stands still has a camera that stands still, so its
    two frames from that phase differ *only* where the other player's body and
    shadow moved: the ground, the sky and its own capsule are pixel for pixel
    the same. That control is what separates "the other player moved" from "my
    own camera moved and everything slid". Taking turns is what gives both
    clients such a window. The pixel comparison below is run, not asserted by
    eye, and both the still-camera and the moving-camera pair are measured so
    the contrast between them is visible rather than claimed.

    Two evidence layers, and the milestone needs both. Everything above is the
    client layer: pixels and `DEMO pos` lines, which prove what each client
    *drew*. They cannot prove what the server *believes*, because the server
    sends waypoints once and never per-tick positions, so every client
    interpolates its polylines by itself. A tick loop that stopped advancing
    players would still hand out paths and still produce moving pixels on every
    screen — and this script passed exactly that sabotage, with displacements
    byte-identical to a healthy run, before the GAMELOG block below existed.

    So the second layer reads the server's NDJSON event log and asserts, per
    player id resolved from that client's `DEMO joined` line: `client_connected`,
    a `move_to`, a `path_assigned`, and an `arrived` whose coordinates match that
    path's endpoint. `arrived` is what a frozen server cannot fake: the tick loop
    emits it only after it has advanced a player onto the last point of its
    polyline. That is all it proves. A tick loop that crossed the whole polyline
    in a single step emits an arrival just as well formed, so the arrival's tick
    is checked against the path's as well: covering that span takes as many ticks
    as the server's own logged walk speed and tick rate say it takes, and a
    teleporting loop misses that count by an order of magnitude. The two layers
    are then tied together. The point the server says the phase-1 walker stopped
    at is the point both clients drew it at.

    Two traps this script exists to step around, both from NOTES.md:

    - Two Godot processes share one `user://` directory and would overwrite
      each other's frames. Every capture here goes to an absolute path under
      -OutDir instead.
    - A cold `client/.godot/` is written by whichever process imports first, and
      two processes importing at once race. One headless warm-up run happens
      before either window opens.

    The port is not guessed: marqued binds 127.0.0.1:0 and announces the port it
    got in its NDJSON event log, which is also the readiness signal.

.PARAMETER Godot
    The Godot 4 executable. Defaults to $env:GODOT, then "godot" on PATH.

.PARAMETER OutDir
    The evidence directory: the eight PNGs, both clients' stdout and stderr, and
    the server's event log and stderr. Defaults to a marque-two-client directory
    under the system temp. Printed on the way out either way, and never deleted —
    the GAMELOG in it is the only server-side proof this run produces.

    Emptied at startup, because every check this script makes on a PNG (it
    exists, it is over 4KB) is satisfied by a stale frame from a previous run,
    and the default path is fixed rather than timestamped. A directory this
    script did not write is refused rather than emptied: it drops a
    `.marque-evidence` marker into the ones it owns and will only clear those.

.PARAMETER ClickA
.PARAMETER ClickB
    Where each client clicks, as a fraction of its viewport. Mirrored about the
    screen's vertical centre line, which with the authored camera framing puts
    the two destinations about 85 degrees apart on the ground: neither walk can
    be mistaken for the other, and the script checks that separation rather
    than assuming it.
#>
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

# How far a walker has to move between the two frames of its own phase, in world
# units, before this script believes it walked. Each scripted click is about six
# units away and the gap between frames is 1.4 seconds at 3.0 units per second,
# so a healthy run clears this twice over.
$MinDisplacement = 2.0

# How far apart the two destinations have to be, in world units, before the two
# walks count as unconfusable.
$MinSeparation = 3.0

# Bounds on the fraction of pixels that may differ between a client's two frames
# from the phase in which it stood still. Above zero because the other player
# has to have moved on screen; well below the moving-camera figure because the
# ground, the sky and this client's own capsule must not have. Measured at 0.75%
# and 1.41% on a healthy run, so both bounds have several times the headroom.
$StillCameraMinDiff = 0.002
$StillCameraMaxDiff = 0.10
$SkyBandControlFailure = "the background is not a control"
$SkyBandFlakeMaxStillFraction = $StillCameraMaxDiff

# How many times more of the frame a walking client's own camera has to disturb
# than a standing one does. Measured at 32x and 37x on a healthy run.
$MovingCameraDiffRatio = 8.0

# The server's own tick rate and walk speed, restated. Both are read back out of
# the run's `server_started` line rather than trusted from here; these are the
# expected values, and a mismatch is a failure rather than a silent
# recalibration against whatever the binary happened to be built with.
$ExpectedTickMS = 150
$ExpectedWalkSpeed = 3.0

# How far off the ideal a walk's duration may be, in ticks, before the tick loop
# counts as implausible. A walk of `span` units takes `ceil(span / (WalkSpeed *
# TickDuration))` ticks exactly, in a healthy run, every time; the tolerance is
# for a path assigned on a tick boundary, not for a server that crossed the
# world in one step. The scripted clicks land about six units out, which is
# fourteen-odd ticks; a server that moves 1000.0 units per tick does it in one.
$MaxWalkTickError = 2

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

# Scratch, deleted at teardown: the built binary and the warm-up logs, nothing
# anybody would want afterwards. Every observable goes to $OutDir instead.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-demo-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
# Presence marks a directory as this script's to empty. Content is for whoever
# finds it and wonders.
$evidenceMarker = Join-Path $OutDir ".marque-evidence"

# How far the server's own world may disagree with what a client drew, in world
# units, before the two layers count as describing different runs. The walker
# stops exactly on the polyline's last point on both sides, so this is slack for
# float printing and a frame of interpolation, not for a real discrepancy.
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

# One client's captures: shot index -> player id -> position.
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

# Two frames, compared pixel for pixel. Returns whether they are byte-identical
# and what fraction of sampled pixels differ.
#
# The fraction is sampled every eighth pixel: it is a ratio, not a forensic
# count, and a full 3.7MB per-pixel walk in PowerShell costs more than the
# precision is worth. The identity check is exact, over every byte, via a hash.
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

        # The top quarter of the frame is sky and far ground. No body is ever
        # drawn there, so it changes if and only if the camera moved. Compared
        # exactly, every byte, because "identical" is the whole point of it:
        # it is the control that separates "the other player moved" from
        # "everything moved".
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

# The server's NDJSON event log, parsed. One object per "GAMELOG "-prefixed
# line; anything else on that stream is runtime noise and is skipped.
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

# Every event of one kind naming one player, oldest first.
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
    # A stale PNG satisfies both frame checks below, so a run that captured
    # nothing would be proven healthy by the last run's leftovers. The default
    # -OutDir is a fixed path reused forever, which is exactly the exposure.
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

    # Each walks in its own phase and watches in the other's. Both are real
    # windows: this is the one run in the whole suite that renders anything.
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
        # Touching Handle caches it. Without it a -PassThru process object reads
        # its ExitCode back as empty once the process is gone, which compares
        # unequal to 0 and fails a healthy run.
        $null = $process.Handle
        $running += @{
            Label = $client.Label
            Process = $process
            Stdout = $stdout
            Stderr = $stderr
            Prefix = $prefix
            Phase = $client.Phase
            # Empty means this client only ever watches, so the server owes it a
            # connection and nothing else.
            Click = $client.Click
            Id = -1
            Positions = $null
        }
    }

    foreach ($client in $running) {
        if ($client.Process.WaitForExit($ClientTimeoutSeconds * 1000)) {
            # The parameterless overload as well: on a -PassThru process the
            # timed overload returns without caching ExitCode, which then reads
            # back empty and compares unequal to everything.
            $client.Process.WaitForExit()
        } else {
            $failures.Add("client $($client.Label) did not finish within $ClientTimeoutSeconds seconds")
            Stop-Process -Id $client.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    # Which player id each client is, so that "the other one" is a fact rather
    # than an assumption about launch order. Ids are assigned as connections
    # arrive and the two clients race to connect, so a is not reliably player 1.
    foreach ($client in $running) {
        $client.Id = Get-JoinedId $client.Stdout
        if ($client.Id -lt 1) {
            $failures.Add("client $($client.Label) never reported the id it joined as")
        }
    }
    # Phase p's captures are shots 2p-1 and 2p, and exactly one player walks in
    # each phase, so these two lookups name every window in the run.
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
        # The exit code alone would let a client that quit early past: the
        # client prints this only after both captures were written.
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

        # One measurement per phase: in phase p, player walkerOfPhase[p] is the
        # only thing moving, and shots 2p-1 and 2p bracket that walk. Doing it
        # for both phases on both clients is what makes the milestone sentence
        # symmetric: each client is measured watching the other one move.
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

        # The two walks have to be tellable apart, or "each sees the other walk"
        # could be one walk seen twice.
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

        # The pixel control. In the phase this client did not walk, its camera
        # never moved, so its two frames may differ only where the other body
        # and its shadow are. In the phase it did walk, the camera moved and the
        # whole ground slides. Measuring both is what makes the first number
        # mean something.
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
        # The control proper. A still camera leaves the sky and far ground byte
        # for byte identical; a moving one cannot.
        if (-not $stillPair.BandIdentical) {
            $failures.Add("client $label stood still but the top quarter of its two frames differs; $SkyBandControlFailure")
            $stillFractions.Add($stillPair.Fraction)
        }
        if ($movingPair.BandIdentical) {
            $failures.Add("client $label walked but the top quarter of its two frames is identical; the camera did not follow it")
        }
        # A ratio, not an absolute: the ground is a two-tone checkerboard, so how
        # many pixels a camera translation changes depends on where the checker
        # edges land, and it measured 24% one way and 52% the other for walks of
        # near-identical length. The contrast against the still-camera figure is
        # the durable signal; the absolute is not.
        if ($movingPair.Fraction -lt ($MovingCameraDiffRatio * $stillPair.Fraction)) {
            $failures.Add("client $label's walking frames differ only $([math]::Round($movingPair.Fraction / $stillPair.Fraction, 1))x as much as its standing-still frames")
        }
    }

    # ------------------------------------------------------------------
    # Layer two: what the server believes.
    #
    # Every assertion above reads a client. Clients interpolate the polylines
    # they are handed, so a tick loop that had stopped advancing players would
    # satisfy all of them — that sabotage was run against this script and it
    # printed its OK marker with displacements byte-identical to a healthy run.
    # The event log is the only evidence in this run that a frozen server
    # cannot produce.
    # ------------------------------------------------------------------
    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) {
        # Without this, every assertion below passes over an empty set.
        $failures.Add("the server wrote no GAMELOG events to $serverOut; this run contains no server-side evidence at all")
    }

    # The run's own constants, read back rather than assumed. A binary built with
    # a different tick rate or a different walk speed would make every walk
    # duration below meaningless, and would do it silently.
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
        # A watcher was never asked to walk, so the server owes it nothing else.
        if ([string]::IsNullOrWhiteSpace($client.Click)) { continue }

        if ((Select-PlayerEvents $events "move_to" $id).Count -lt 1) {
            $failures.Add("client $label clicked but the server logged no move_to for player $id; the intent never reached it")
        }

        $assigned = Select-PlayerEvents $events "path_assigned" $id
        if ($assigned.Count -lt 1) {
            $failures.Add("the server assigned player $id (client $label) no path; there was nothing for anyone to walk")
            continue
        }
        # The last one. A mid-walk click replaces the path, and it is the walk
        # the run ends on that an arrival has to match.
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

        # The assertion this block exists for. The tick loop emits arrived only
        # after it has advanced a player onto the last point of its polyline. A
        # server that validates move_to, assigns a path, broadcasts it and then
        # never moves anybody writes every other event in this log and not this
        # one.
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
        # The arrival above says the walk finished, not that it was walked. A
        # tick loop moving players 1000.0 units per step reaches the endpoint on
        # its first tick and logs an arrival indistinguishable from a healthy
        # one. Its duration is the part it cannot forge.
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

    # The two layers tied to each other. The phase-1 walker's ~2.0s walk is long
    # finished by shot 4, which comes 4.8s after its click, so by then every
    # client must be drawing that body exactly where the server says it stopped.
    # Displacement alone says both sides saw motion; this says they saw the same
    # motion.
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
            # Same hole as interop_test.ps1's: a server that dies after the last
            # frame the clients awaited would otherwise be reported as a clean
            # run.
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
    # Scratch only: the built binary. Every observable is in $OutDir and stays
    # there, because the GAMELOG this run's server-side assertions read is the
    # only copy of the server's account of it.
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
