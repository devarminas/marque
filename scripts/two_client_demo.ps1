<#
.SYNOPSIS
    The M0 milestone, on screen: two real windowed clients on one real server,
    one clicks the ground, and both watch the walk. Each client screenshots
    itself twice. Exits 0 only if both saw two players and both saw the walker
    move between their own two frames.

.DESCRIPTION
    This is the visual half of M0e. `scripts/interop_test.ps1` proves the same
    thing headless and in far more detail; this one exists because a headless
    run cannot show a capsule, a cast shadow, or the fact that the two clients
    are drawing the same world. NOTES.md says the game screenshots itself and
    the desktop is not automated, so the click is a synthesised input event
    inside the client rather than a driven mouse, and the capture is the
    client's own viewport.

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
    Where the four PNGs land. Defaults to a marque-two-client directory under
    the system temp. Printed on the way out either way.

.PARAMETER ClickAt
    Where the clicking client clicks, as a fraction of its viewport. Off centre
    in both axes so the resulting walk is long.
#>
[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-two-client"),
    [string] $ClickAt = "0.30,0.72",
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# How far the walker has to move between a client's own two frames, in world
# units, before this script believes it walked. The scripted click is five or
# more units away and the gap between frames is 1.8 seconds at 3.0 units per
# second, so a healthy run clears this several times over.
$MinDisplacement = 2.0

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

    # A clicks and walks; B only watches. Both capture twice, and both are real
    # windows: this is the one run in the whole suite that renders anything.
    $clients = @(
        @{ Label = "a"; Click = $ClickAt; Position = "40,60" },
        @{ Label = "b"; Click = "";       Position = "700,140" }
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
        if ($client.Click) { $godotArgs += @("--click", $client.Click) }

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
            Clicked = [bool]$client.Click
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

    $mover = -1
    foreach ($client in $running) {
        if ($client.Clicked) { $mover = Get-JoinedId $client.Stdout }
    }
    if ($mover -lt 1) { $failures.Add("the clicking client never reported the id it joined as") }

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

        foreach ($index in 1, 2) {
            $shot = "$($client.Prefix)_$index.png"
            if (-not (Test-Path $shot)) {
                $failures.Add("client $label never wrote $shot")
                continue
            }
            $size = (Get-Item $shot).Length
            Write-Host "==> $shot ($size bytes)"
            if ($size -lt 4096) { $failures.Add("$shot is only $size bytes; that is not a frame") }
        }

        $positions = Read-Positions $client.Stdout
        foreach ($index in 1, 2) {
            if (-not $positions.ContainsKey($index)) {
                $failures.Add("client $label reported no bodies for shot $index")
                continue
            }
            $drawn = $positions[$index].Keys.Count
            if ($drawn -lt 2) {
                $failures.Add("client $label drew $drawn body/bodies in shot $index; the milestone is two")
            }
        }

        if ($mover -lt 1 -or -not $positions.ContainsKey(1) -or -not $positions.ContainsKey(2)) { continue }
        if (-not $positions[1].ContainsKey($mover) -or -not $positions[2].ContainsKey($mover)) {
            $failures.Add("client $label did not draw the walker (player $mover) in both shots")
            continue
        }
        $before = $positions[1][$mover]
        $after = $positions[2][$mover]
        $moved = [math]::Sqrt([math]::Pow($after[0] - $before[0], 2) + [math]::Pow($after[1] - $before[1], 2))
        Write-Host ("==> client {0}: player {1} moved {2:N3} units, ({3:N3}, {4:N3}) -> ({5:N3}, {6:N3})" -f `
            $label, $mover, $moved, $before[0], $before[1], $after[0], $after[1])
        if ($moved -lt $MinDisplacement) {
            $failures.Add("client $label saw the walker move only $moved units between its two frames")
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
