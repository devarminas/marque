[CmdletBinding()]
param(
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-seed-class-kits"),
    [int] $ReadyTimeoutSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-seed-class-kits-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
$evidenceMarker = Join-Path $OutDir ".marque-evidence"

$server = $null
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure([string] $message) { $failures.Add($message) }

try {
    if (Test-Path $OutDir) {
        if (-not (Test-Path $evidenceMarker)) {
            throw "Refusing to empty $OutDir without .marque-evidence marker"
        }
        Remove-Item -Recurse -Force $OutDir
    }
    New-Item -ItemType Directory -Path $OutDir | Out-Null
    Set-Content -Path $evidenceMarker -Value "marque-seed-class-kits"

    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    $server = Start-Process -FilePath $binary -ArgumentList @(
        "-addr", "127.0.0.1:0",
        "-seed-class-kits"
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

    if (-not $started.seed_class_kits) {
        Add-Failure "server_started.seed_class_kits is false or missing"
    }
    if ($null -ne $started.join_kit) {
        $joinKit = @($started.join_kit)
        if ($joinKit.Count -gt 0) {
            Add-Failure "join_kit is $($joinKit -join ','), want empty"
        }
    }
    $kitSeeds = @($started.class_kit_seeds)
    if ($kitSeeds.Count -lt 1) {
        Add-Failure "class_kit_seeds empty"
    }

    $spawned = New-Object System.Collections.Generic.List[string]
    Start-Sleep -Milliseconds 200
    foreach ($line in Get-Content $serverOut -ErrorAction SilentlyContinue) {
        if ($line -match 'GAMELOG .*\"ev\":\"item_spawned\"') {
            $ev = ($line -replace '^GAMELOG ', '') | ConvertFrom-Json
            if ($ev.kind) { $spawned.Add([string]$ev.kind) }
        }
    }

    $expected = @{}
    foreach ($s in $kitSeeds) {
        $k = [string]$s.kind
        if ($expected.ContainsKey($k)) {
            Add-Failure "duplicate class_kit_seeds kind $k"
        }
        $expected[$k] = $true
        if ($spawned -notcontains $k) {
            Add-Failure "missing item_spawned for $k"
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host "FAILURES:"
        $failures | ForEach-Object { Write-Host "  $_" }
        exit 1
    }
    Write-Host "SEED CLASS KITS DEMO OK"
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
