[CmdletBinding()]
param(
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-admin-give-class-kits"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $HarnessTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-admin-give-class-kits-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$harness = Join-Path $work "admin_give_kits.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
$harnessOut = Join-Path $OutDir "harness.stdout.log"
$harnessErr = Join-Path $OutDir "harness.stderr.log"
$evidenceMarker = Join-Path $OutDir ".marque-evidence"

$server = $null
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure([string] $message) { $failures.Add($message) }

function Read-GameLog([string] $path) {
    $events = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $path)) { return , $events }
    foreach ($line in Get-Content $path) {
        if (-not $line.StartsWith("GAMELOG ")) { continue }
        $events.Add(($line.Substring(8) | ConvertFrom-Json))
    }
    return , $events
}

try {
    if (Test-Path $OutDir) {
        if (-not (Test-Path $evidenceMarker)) {
            throw "Refusing to empty $OutDir without .marque-evidence marker"
        }
        Remove-Item -Recurse -Force $OutDir
    }
    New-Item -ItemType Directory -Path $OutDir | Out-Null
    Set-Content -Path $evidenceMarker -Value "marque-admin-give-class-kits"

    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build marqued failed: $LASTEXITCODE" }
        & go build -o $harness ./cmd/admin_give_kits
        if ($LASTEXITCODE -ne 0) { throw "go build admin_give_kits failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    $server = Start-Process -FilePath $binary -ArgumentList @(
        "-addr", "127.0.0.1:0",
        "-admin"
    ) -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr `
        -NoNewWindow -PassThru

    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    $started = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $serverOut) {
            foreach ($line in Get-Content $serverOut -ErrorAction SilentlyContinue) {
                if ($line -match 'GAMELOG .*\"ev\":\"server_started\"') {
                    $started = ($line -replace '^GAMELOG ', '') | ConvertFrom-Json
                    break
                }
            }
        }
        if ($started) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $started) { throw "server_started not seen within ${ReadyTimeoutSeconds}s" }

    if (-not $started.admin) {
        Add-Failure "server_started.admin is false or missing"
    }
    $startedProps = @($started.PSObject.Properties.Name)
    if ($startedProps -contains "seed_class_kits") {
        Add-Failure "server_started still carries retired seed_class_kits"
    }
    if ($startedProps -contains "class_kit_seeds") {
        Add-Failure "server_started still carries retired class_kit_seeds"
    }
    if ($null -ne $started.join_kit) {
        $joinKit = @($started.join_kit)
        if ($joinKit.Count -gt 0) {
            Add-Failure "join_kit is $($joinKit -join ','), want empty"
        }
    }

    $listenAddr = [string]$started.addr
    if ([string]::IsNullOrWhiteSpace($listenAddr)) {
        throw "server_started.addr missing"
    }

    $harnessProc = Start-Process -FilePath $harness -ArgumentList @(
        "-addr", $listenAddr,
        "-timeout", "${HarnessTimeoutSeconds}s"
    ) -RedirectStandardOutput $harnessOut -RedirectStandardError $harnessErr `
        -NoNewWindow -PassThru -Wait
    if ($harnessProc.ExitCode -ne 0) {
        Add-Failure "admin_give_kits exit $($harnessProc.ExitCode)"
    }

    $gave = New-Object System.Collections.Generic.List[string]
    $harnessOk = $false
    if (Test-Path $harnessOut) {
        foreach ($line in Get-Content $harnessOut) {
            if ($line -match '^GAVE (\S+)\s*$') { $gave.Add($Matches[1]) }
            if ($line -eq "ADMIN GIVE CLASS KITS HARNESS OK") { $harnessOk = $true }
        }
    }
    if (-not $harnessOk) {
        Add-Failure "harness missing ADMIN GIVE CLASS KITS HARNESS OK"
    }
    if ($gave.Count -lt 1) {
        Add-Failure "harness gave no kinds"
    }
    $dup = $gave | Group-Object | Where-Object { $_.Count -gt 1 }
    foreach ($d in $dup) {
        Add-Failure "duplicate give kind $($d.Name)"
    }

    Start-Sleep -Milliseconds 200
    $events = Read-GameLog $serverOut
    $adminOk = New-Object System.Collections.Generic.HashSet[string]
    foreach ($ev in $events) {
        if ($ev.ev -ne "admin") { continue }
        if ([string]$ev.result -ne "ok") { continue }
        if ([string]$ev.cmd -ne "give") { continue }
        $args = @($ev.args)
        if ($args.Count -ge 1) {
            [void]$adminOk.Add([string]$args[0])
        }
    }
    foreach ($kind in $gave) {
        if (-not $adminOk.Contains($kind)) {
            Add-Failure "missing GAMELOG admin give ok for $kind"
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host "FAILURES:"
        $failures | ForEach-Object { Write-Host "  $_" }
        if (Test-Path $harnessErr) {
            Write-Host "--- harness stderr ---"
            Get-Content $harnessErr | Write-Host
        }
        exit 1
    }
    Write-Host "ADMIN GIVE CLASS KITS DEMO OK"
    exit 0
}
finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $work) {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
}
