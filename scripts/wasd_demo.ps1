[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-wasd"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-wasd-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
$clientOut = Join-Path $OutDir "client.stdout.log"
$clientErr = Join-Path $OutDir "client.stderr.log"
$shotsPrefix = Join-Path $OutDir "wasd"
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

try {
    if (Test-Path $OutDir) {
        if (-not (Test-Path $evidenceMarker)) {
            throw "Refusing to empty $OutDir without .marque-evidence marker"
        }
        Remove-Item -Recurse -Force $OutDir
    }
    New-Item -ItemType Directory -Path $OutDir | Out-Null
    Set-Content -Path $evidenceMarker -Value "marque-wasd"

    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    $server = Start-Process -FilePath $binary -ArgumentList @("-addr", "127.0.0.1:0") `
        -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr `
        -NoNewWindow -PassThru

    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    $wsUrl = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $serverOut) {
            foreach ($line in Get-Content $serverOut -ErrorAction SilentlyContinue) {
                if ($line -match 'GAMELOG .*\"ev\":\"server_started\"') {
                    $json = ($line -replace '^GAMELOG ', '') | ConvertFrom-Json
                    $wsUrl = "ws://$($json.addr)/ws"
                    break
                }
            }
        }
        if ($wsUrl) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $wsUrl) { throw "server_started not seen within ${ReadyTimeoutSeconds}s" }
    Write-Host "SERVER $wsUrl"

    $client = Start-Process -FilePath $Godot -ArgumentList @(
        "--path", $clientDir,
        "--",
        "--server", $wsUrl,
        "--wasd-shots", $shotsPrefix
    ) -RedirectStandardOutput $clientOut -RedirectStandardError $clientErr -PassThru

    $client.WaitForExit($ClientTimeoutSeconds * 1000) | Out-Null
    if (-not $client.HasExited) {
        Stop-Process -Id $client.Id -Force
        Add-Failure "client timed out after ${ClientTimeoutSeconds}s"
    } else {
        try { $client.Refresh() } catch { }
        $code = $client.ExitCode
        if ($null -ne $code -and [int]$code -ne 0) {
            Add-Failure "client exit $code"
        }
    }

    $done = $false
    $displacement = $null
    $posLines = 0
    if (Test-Path $clientOut) {
        foreach ($line in Get-Content $clientOut) {
            if ($line -match '^DEMO pos ') { $posLines++ }
            if ($line -match '^DEMO move_displacement ([0-9.]+)') {
                $displacement = [double]$Matches[1]
            }
            if ($line -match '^DEMO done\s*$') { $done = $true }
            if ($line -match '^DEMO FAIL ') { Add-Failure $line.Trim() }
        }
    }
    if (-not $done) { Add-Failure "missing DEMO done" }
    if ($posLines -lt 2) { Add-Failure "DEMO pos lines=$posLines, want >= 2" }
    if ($null -eq $displacement -or $displacement -lt 1.5) {
        Add-Failure "DEMO move_displacement=$displacement, want >= 1.5"
    }

    $moveEvents = 0
    $pathEvents = 0
    if (Test-Path $serverOut) {
        foreach ($line in Get-Content $serverOut) {
            if ($line -match 'GAMELOG ') {
                $json = ($line -replace '^GAMELOG ', '') | ConvertFrom-Json
                if ($json.ev -eq "move") { $moveEvents++ }
                if ($json.ev -eq "path_assigned") { $pathEvents++ }
            }
        }
    }
    if ($moveEvents -lt 1) { Add-Failure "GAMELOG move events=$moveEvents, want >= 1" }
    if ($pathEvents -lt 1) { Add-Failure "GAMELOG path_assigned events=$pathEvents, want >= 1" }

    if ($failures.Count -gt 0) {
        Show-File "client stdout" $clientOut
        Show-File "client stderr" $clientErr
        Show-File "server stdout" $serverOut
        foreach ($f in $failures) { Write-Host "FAIL: $f" }
        exit 1
    }
    Write-Host "WASD DEMO OK"
    exit 0
} finally {
    if ($null -ne $server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $work) {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
}
