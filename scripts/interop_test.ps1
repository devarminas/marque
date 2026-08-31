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

    The suite skips itself when MARQUE_WS_URL is unset, so a green Godot exit is
    not on its own proof that anything was tested. This script requires the
    suite's "INTEROP RAN" line and fails without it.

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

    # A green exit proves nothing on its own: the interop suite skips when it
    # has no URL, and a skip that nothing checks is a suite that quietly stopped
    # running.
    $transcript = ""
    if (Test-Path $godotOut) { $transcript = Get-Content -Path $godotOut -Raw }
    if ($transcript -match "INTEROP SKIPPED") {
        $failures.Add("the interop suite skipped itself despite MARQUE_WS_URL being set")
    }
    if ($transcript -match "INTEROP RAN: (\d+) assertions, (\d+) failed") {
        $ran = [int]$Matches[1]
        $failed = [int]$Matches[2]
        Write-Host ""
        Write-Host "==> interop: $ran assertions, $failed failed"
        if ($ran -lt 1) { $failures.Add("the interop suite ran no assertions") }
        if ($failed -ne 0) { $failures.Add("$failed interop assertion(s) failed") }
    } else {
        $failures.Add("the interop suite never reported (no 'INTEROP RAN' line)")
    }
} catch {
    # The location matters: most of what can go wrong here is environmental
    # (no Go, no Godot, a port that vanished) and the line number says which.
    $failures.Add("$($_.Exception.Message) [$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())]")
} finally {
    if ($null -ne $server -and -not $server.HasExited) {
        Write-Host "==> stopping marqued (pid $($server.Id))"
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
        $server.WaitForExit(5000) | Out-Null
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
