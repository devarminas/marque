# Shared helpers for Project Marque PowerShell UX demos.
# Dot-source from a demo:  . (Join-Path $PSScriptRoot "marque-demo-lib.ps1")
#
# On client failure, read stderr (and the redirected *.stderr.log) before
# treating DEMO stdout as authoritative — Godot often dies with the real
# cause only on stderr.

Set-StrictMode -Version Latest

$script:MarqueDemoFailures = $null

function New-MarqueDemoFailures {
    $script:MarqueDemoFailures = New-Object System.Collections.Generic.List[string]
    return , $script:MarqueDemoFailures
}

function Add-Failure([string] $message) {
    if ($null -eq $script:MarqueDemoFailures) {
        throw "call New-MarqueDemoFailures before Add-Failure"
    }
    [void]$script:MarqueDemoFailures.Add($message)
}

function Show-File([string] $label, [string] $path) {
    if (-not (Test-Path $path)) { return }
    $content = Get-Content -Path $path -Raw
    if ([string]::IsNullOrWhiteSpace($content)) { return }
    Write-Host ""
    Write-Host "--- $label ---"
    Write-Host $content.TrimEnd()
}

function Initialize-MarqueEvidenceDir {
    param(
        [Parameter(Mandatory)][string] $OutDir,
        [Parameter(Mandatory)][string] $SourceScript
    )
    $evidenceMarker = Join-Path $OutDir ".marque-evidence"
    if (Test-Path $OutDir) {
        $stale = @(Get-ChildItem -LiteralPath $OutDir -Force)
        if ($stale.Count -gt 0) {
            if (-not (Test-Path $evidenceMarker)) {
                throw ("$OutDir is not empty and carries no .marque-evidence marker; refusing to run.")
            }
            Write-Host "==> clearing $($stale.Count) leftover item(s) from $OutDir"
            Remove-Item -LiteralPath $stale.FullName -Recurse -Force
        }
    } else {
        New-Item -ItemType Directory -Path $OutDir | Out-Null
    }
    Set-Content -LiteralPath $evidenceMarker -Encoding utf8 `
        -Value "Evidence from $SourceScript. Its next run empties this directory."
    return $evidenceMarker
}

function Read-GameLog([string] $path) {
    $events = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $path)) { return , $events }
    foreach ($line in Get-Content -Path $path) {
        if (-not $line.StartsWith("GAMELOG ")) { continue }
        $events.Add(($line.Substring(8) | ConvertFrom-Json))
    }
    return , $events
}

function Select-Events($events, [string] $kind, [int] $player = -1) {
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($event in $events) {
        if ($event.ev -ne $kind) { continue }
        if ($player -ge 0) {
            if ($event.PSObject.Properties.Name -notcontains "player") { continue }
            if ([int]$event.player -ne $player) { continue }
        }
        $hits.Add($event)
    }
    return , $hits
}

function Select-PlayerEvents($events, [string] $kind, [int] $player) {
    Select-Events $events $kind $player
}

function Test-HasKind($slots, [string] $kind) {
    if ($null -eq $slots) { return $false }
    foreach ($key in $slots.Keys) {
        if ($slots[$key] -eq $kind) { return $true }
    }
    return $false
}

function Wait-MarqueClient {
    param(
        [Parameter(Mandatory)] $Process,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [string] $Label = "client"
    )
    if ($Process.WaitForExit($TimeoutSeconds * 1000)) {
        $Process.WaitForExit()
        return $true
    }
    Add-Failure "$Label did not finish within $TimeoutSeconds seconds"
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    return $false
}

function Wait-MarqueClients {
    param(
        [Parameter(Mandatory)] $Clients,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $alive = @($Clients | Where-Object { -not $_.Process.HasExited })
        if ($alive.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    }
    foreach ($client in $Clients) {
        $name = $null
        if ($client.PSObject.Properties.Name -contains "Name" -and $client.Name) {
            $name = "client-$($client.Name)"
        } elseif ($client -is [hashtable] -and $client.ContainsKey("Name") -and $client.Name) {
            $name = "client-$($client.Name)"
        } elseif ($client.PSObject.Properties.Name -contains "Label" -and $client.Label) {
            $name = "client $($client.Label)"
        } elseif ($client -is [hashtable] -and $client.ContainsKey("Label") -and $client.Label) {
            $name = "client $($client.Label)"
        } else {
            $name = "client"
        }
        if (-not $client.Process.HasExited) {
            Add-Failure "$name did not finish within $TimeoutSeconds seconds"
            Stop-Process -Id $client.Process.Id -Force -ErrorAction SilentlyContinue
            $client.Process.WaitForExit(5000) | Out-Null
        } else {
            $client.Process.WaitForExit() | Out-Null
        }
    }
}

function Write-MarqueDemoResult {
    param(
        [Parameter(Mandatory)][string] $OkMarker,
        [Parameter(Mandatory)][string] $FailMarker,
        [Parameter(Mandatory)][string] $EvidenceLine,
        $Failures = $script:MarqueDemoFailures
    )
    Write-Host ""
    Write-Host $EvidenceLine
    if ($null -eq $Failures -or $Failures.Count -eq 0) {
        Write-Host $OkMarker
        exit 0
    }
    Write-Host $FailMarker
    foreach ($failure in $Failures) { Write-Host "  - $failure" }
    exit 1
}
