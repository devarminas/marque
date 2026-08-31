<#
.SYNOPSIS
    Builds marqued, starts it, runs the Godot headless test suite against it,
    and shuts it down. Exits 0 only if everything passed.

.DESCRIPTION
    The M0b interop test needs a real server on a real socket, and a test that
    needs a human to start a server in another window is not a test. This is the
    one command; every later unit runs it.

    The port is not guessed. The server is told to listen on 127.0.0.1:0, binds
    a free port itself, and announces the one it got in its NDJSON event log:

        GAMELOG {"addr":"127.0.0.1:54321","ev":"server_started",...}

    That line is also the readiness signal. Waiting for it beats sleeping a
    guessed interval, and the line cannot appear before the listener is bound,
    because the server binds before it announces.

    The suites that need a server skip themselves when MARQUE_WS_URL is unset,
    so a green Godot exit is not on its own proof that anything was tested. This
    script requires each of their "RAN" lines, and the runner's own "PASS:" line,
    and fails without any of them.

    It also requires the server to still be running when the suite ends. A
    marqued that panicked after the last frame the suite awaited satisfies every
    assertion above it, so the shutdown is the only place that can notice, and
    anything on the server's stderr is a failure for the same reason: the event
    log is stdout, and nothing routine is written to stderr.

.PARAMETER Godot
    The Godot 4 executable. Defaults to $env:GODOT, then "godot" on PATH.

.PARAMETER QuitAfter
    Frames to bound the Godot run. Must stay above the runner's own watchdog or
    the watchdog can never fire.
#>
[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [int] $QuitAfter = 900,
    [int] $ReadyTimeoutSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-interop-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $work "server.stdout.log"
$serverErr = Join-Path $work "server.stderr.log"
$godotOut = Join-Path $work "godot.stdout.log"
$godotErr = Join-Path $work "godot.stderr.log"

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

try {
    Write-Host "==> building marqued"
    # Built outside the repository: server/ is not this unit's to write to, not
    # even with an ignored artifact.
    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    Write-Host "==> starting marqued on a free port"
    # Port 0 lets the kernel pick. Nothing here assumes 8080 is free, and two
    # runs at once cannot collide.
    $server = Start-Process -FilePath $binary `
        -ArgumentList "-addr", "127.0.0.1:0" `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
    # Touching Handle caches it. Without it a -PassThru process object reads its
    # ExitCode back as empty once the process is gone, and the message below
    # about a server that died would not be able to say what it died of.
    $null = $server.Handle

    $address = $null
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($server.HasExited) {
            throw "marqued exited with code $($server.ExitCode) before it announced an address"
        }
        if (Test-Path $serverOut) {
            $line = Select-String -Path $serverOut -Pattern '"ev":"server_started"' `
                -SimpleMatch:$false -List
            if ($null -ne $line) {
                if ($line.Line -match '"addr":"([^"]+)"') {
                    $address = $Matches[1]
                    break
                }
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

    Write-Host "==> running the Godot suite"
    $env:MARQUE_WS_URL = $url
    # Every element a string, and paths quoted: Start-Process joins the array
    # into one command line and a bare int or an unquoted space breaks it.
    $godotArgs = @(
        "--headless",
        "--path", ('"' + $clientDir + '"'),
        "--script", "res://tests/run_tests.gd",
        "--quit-after", $QuitAfter.ToString()
    )
    $godotRun = Start-Process -FilePath $Godot -ArgumentList $godotArgs `
        -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput $godotOut -RedirectStandardError $godotErr

    Show-File "godot stdout" $godotOut
    Show-File "godot stderr" $godotErr

    if ($godotRun.ExitCode -ne 0) {
        $failures.Add("the Godot suite exited $($godotRun.ExitCode)")
    }

    # A green exit proves nothing on its own: a suite can quit before asserting
    # anything and still exit 0, and the server-backed suites skip when they
    # have no URL. A skip that nothing checks is a suite that quietly stopped
    # running.
    $transcript = ""
    if (Test-Path $godotOut) { $transcript = Get-Content -Path $godotOut -Raw }

    # The runner's own verdict. STANDING-ORDERS.md requires this line rather
    # than the exit code, because the exit code is what the false passes look
    # like.
    if ($transcript -match "PASS: (\d+) assertion\(s\) held across (\d+) suite\(s\)") {
        Write-Host ""
        Write-Host "==> runner: PASS, $($Matches[1]) assertions across $($Matches[2]) suites"
    } else {
        $failures.Add("the Godot runner never printed a 'PASS:' line")
    }

    foreach ($suite in @("INTEROP", "WIRING")) {
        if ($transcript -match "$suite SKIPPED") {
            $failures.Add("the $suite suite skipped itself despite MARQUE_WS_URL being set")
        }
        if ($transcript -match "$suite RAN: (\d+) assertions, (\d+) failed") {
            $ran = [int]$Matches[1]
            $failed = [int]$Matches[2]
            Write-Host "==> $suite`: $ran assertions, $failed failed"
            if ($ran -lt 1) { $failures.Add("the $suite suite ran no assertions") }
            if ($failed -ne 0) { $failures.Add("$failed $suite assertion(s) failed") }
        } else {
            $failures.Add("the $suite suite never reported (no '$suite RAN' line)")
        }
    }
} catch {
    # The location matters: most of what can go wrong here is environmental
    # (no Go, no Godot, a port that vanished) and the line number says which.
    $failures.Add("$($_.Exception.Message) [$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())]")
} finally {
    if ($null -ne $server) {
        if ($server.HasExited) {
            # The server outliving the suite is part of the contract, and this
            # is the only place that can check it. A marqued that panics after
            # the last frame the suite awaited satisfies every assertion above
            # and would otherwise be reported as a clean run.
            $failures.Add("marqued exited on its own with code $($server.ExitCode); it must outlive the suite")
        } else {
            Write-Host "==> stopping marqued (pid $($server.Id))"
            Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
            $server.WaitForExit(5000) | Out-Null
        }
    }
    # The event log is stdout. Nothing routine goes to stderr, so anything here
    # is a panic or a fatal, whether or not the process is still alive.
    if (Test-Path $serverErr) {
        $stderrText = Get-Content -Path $serverErr -Raw
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            $firstLine = $stderrText.Trim() -split "`r?`n" | Select-Object -First 1
            $failures.Add("marqued wrote to stderr: $firstLine")
        }
    }
    Show-File "marqued event log" $serverOut
    Show-File "marqued stderr" $serverErr
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "INTEROP OK"
    exit 0
}
Write-Host "INTEROP FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1
