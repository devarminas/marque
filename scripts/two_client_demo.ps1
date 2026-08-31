<#
.SYNOPSIS
    The M0 milestone, on screen and in both directions: two real windowed
    clients on one real server, each clicking the ground in turn while the other
    watches. Each client screenshots itself four times. Exits 0 only if each
    client saw two bodies in every frame and saw *the other* player move.

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
    Where the eight PNGs land, four per client. Defaults to a marque-two-client
    directory under the system temp. Printed on the way out either way.

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

# How many times more of the frame a walking client's own camera has to disturb
# than a standing one does. Measured at 32x and 37x on a healthy run.
$MovingCameraDiffRatio = 8.0

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-demo-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $work "server.stdout.log"
$serverErr = Join-Path $work "server.stderr.log"

$server = $null
$failures = New-Object System.Collections.Generic.List[string]

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

function Get-JoinedId([string] $path) {
    if (-not (Test-Path $path)) { return -1 }
    foreach ($line in Get-Content -Path $path) {
        if ($line -match '^DEMO joined (\d+)\s*$') { return [int]$Matches[1] }
    }
    return -1
}

try {
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
        -RedirectStandardOutput (Join-Path $work "warm.stdout.log") `
        -RedirectStandardError (Join-Path $work "warm.stderr.log")
    if ($warm.ExitCode -ne 0) { throw "the Godot warm-up run exited $($warm.ExitCode)" }

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
        $stdout = Join-Path $work ("client-" + $client.Label + ".stdout.log")
        $stderr = Join-Path $work ("client-" + $client.Label + ".stderr.log")
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
            $failures.Add("client $label stood still but the top quarter of its two frames differs; the background is not a control")
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
    Show-File "marqued event log" $serverOut
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "screenshots: $OutDir"
if ($failures.Count -eq 0) {
    Write-Host "TWO CLIENT DEMO OK"
    exit 0
}
Write-Host "TWO CLIENT DEMO FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1
