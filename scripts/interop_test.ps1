[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [int] $QuitAfter = 1600,
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
    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
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

    $transcript = ""
    if (Test-Path $godotOut) { $transcript = Get-Content -Path $godotOut -Raw }

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
    $failures.Add("$($_.Exception.Message) [$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())]")
} finally {
    if ($null -ne $server) {
        if ($server.HasExited) {
            $failures.Add("marqued exited on its own with code $($server.ExitCode); it must outlive the suite")
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
