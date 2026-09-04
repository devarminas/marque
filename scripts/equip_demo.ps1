<#
.SYNOPSIS
    The M3 milestone, on screen and in the server's ledger: one windowed client
    opens equipment on the left, right-clicks the join-kit axe to equip it, sees
    the weapon slot occupied, then unequips back to the bag. Exits 0 only if the
    GAMELOG records one equip and one unequiv, the client's DEMO lines report
    each step, and three screenshots were written.

.DESCRIPTION
    M3d closes M3 by observation. The load-bearing claims are server-side facts
    (the axe moved between bag slot 0 and worn slot weapon exactly once each
    way) and client-side observations (the panel opened left, the worn slot
    showed the axe after equip and emptied after unequip, the bag lost then
    regained the axe). Neither layer substitutes for the other.

.PARAMETER Godot
    The Godot 4 executable. Defaults to $env:GODOT, then "godot" on PATH.

.PARAMETER OutDir
    Evidence directory. Default `$env:TEMP\marque-equip`. Emptied at the start of
    each run when it carries this script's `.marque-evidence` marker.
#>
[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-equip"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AxeKind = "axe"
$WeaponWorn = "weapon"
$AxeBagSlot = 0
$PanelLeftInsetMax = 80.0

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-equip-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
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

function Read-ClientReport([string] $path) {
    $report = @{
        Joined = -1
        Failures = New-Object System.Collections.Generic.List[string]
        Done = $false
        Shots = @{}
        Inventory = @{}
        Slots = @{}
        Worn = @{}
        EquipOpen = @{}
    }
    if (-not (Test-Path $path)) { return $report }
    foreach ($line in Get-Content -Path $path) {
        switch -Regex ($line) {
            '^DEMO joined (\d+)\s*$' { $report.Joined = [int]$Matches[1] }
            '^DEMO FAIL (.+)$' { $report.Failures.Add($Matches[1].Trim()) }
            '^DEMO done\s*$' { $report.Done = $true }
            '^DEMO shot (\d+) (.+)$' { $report.Shots[[int]$Matches[1]] = $Matches[2].Trim() }
            '^DEMO equipopen (\d+) (-?[0-9.eE+-]+) (-?[0-9.eE+-]+) (-?[0-9.eE+-]+) (\d+)\s*$' {
                $report.EquipOpen[[int]$Matches[1]] = @{
                    Left = [double]$Matches[2]
                    EndX = [double]$Matches[3]
                    ViewportW = [double]$Matches[4]
                    Visible = [int]$Matches[5]
                }
            }
            '^DEMO inv (\d+) (\d+) (\d+)\s*$' {
                $report.Inventory[[int]$Matches[1]] = @{
                    Occupied = [int]$Matches[2]
                    Size = [int]$Matches[3]
                }
            }
            '^DEMO invslot (\d+) (\d+) (\S+)\s*$' {
                $shot = [int]$Matches[1]
                if (-not $report.Slots.ContainsKey($shot)) { $report.Slots[$shot] = @{} }
                $report.Slots[$shot][[int]$Matches[2]] = $Matches[3]
            }
            '^DEMO worn (\d+) (\S+)\s*$' {
                $report.Worn[[int]$Matches[1]] = @{ Slot = $Matches[2]; Kind = "" }
            }
            '^DEMO worn (\d+) (\S+) (\S+)\s*$' {
                $report.Worn[[int]$Matches[1]] = @{ Slot = $Matches[2]; Kind = $Matches[3] }
            }
        }
    }
    return $report
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

try {
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
        -Value "Evidence from scripts/equip_demo.ps1. Its next run empties this directory."

    Write-Host "==> building marqued"
    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    Write-Host "==> warming the Godot import cache"
    $warm = Start-Process -FilePath $Godot `
        -ArgumentList @("--headless", "--path", ('"' + $clientDir + '"'), "--quit-after", "20") `
        -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput (Join-Path $OutDir "warm.stdout.log") `
        -RedirectStandardError (Join-Path $OutDir "warm.stderr.log")
    if ($warm.ExitCode -ne 0) {
        throw "the Godot warm-up run exited $($warm.ExitCode)"
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
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $address) { throw "marqued never logged server_started within $ReadyTimeoutSeconds seconds" }
    $url = "ws://$address/ws"
    Write-Host "==> marqued listening at $url (pid $($server.Id))"

    $prefix = Join-Path $OutDir "client"
    $stdout = Join-Path $OutDir "client.stdout.log"
    $stderr = Join-Path $OutDir "client.stderr.log"
    $godotArgs = @(
        "--path", ('"' + $clientDir + '"'),
        "--position", "40,60",
        "--",
        "--server", $url,
        "--equip-shots", ('"' + $prefix + '"')
    )

    Write-Host "==> launching client"
    $client = Start-Process -FilePath $Godot -ArgumentList $godotArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $client.Handle

    if ($client.WaitForExit($ClientTimeoutSeconds * 1000)) {
        $client.WaitForExit()
    } else {
        Add-Failure "client did not finish within $ClientTimeoutSeconds seconds"
        Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
    }

    Show-File "client stdout" $stdout
    Show-File "client stderr" $stderr

    if ($client.HasExited) {
        $code = $client.ExitCode
        if ($null -eq $code) {
            Add-Failure "client exit code could not be read"
        } elseif ($code -ne 0) {
            Add-Failure "client exited $code"
        }
    }

    $report = Read-ClientReport $stdout
    if ($report.Joined -lt 1) {
        Add-Failure "client never reported the id it joined as"
    }
    if ($report.Failures.Count -gt 0) {
        foreach ($reason in $report.Failures) {
            Add-Failure "client reported DEMO FAIL: $reason"
        }
    }
    if (-not $report.Done) {
        Add-Failure "client never reported 'DEMO done'"
    }

    foreach ($index in 1, 2, 3) {
        $shot = "$prefix`_$index.png"
        if (-not (Test-Path $shot)) {
            Add-Failure "client never wrote $shot"
            continue
        }
        $size = (Get-Item $shot).Length
        Write-Host "==> $shot ($size bytes)"
        if ($size -lt 4096) { Add-Failure "$shot is only $size bytes; that is not a frame" }
    }

    # AC1: equipment panel visible and left of centre.
    if (-not $report.EquipOpen.ContainsKey(1)) {
        Add-Failure "client never reported equipment panel layout for shot 1"
    } else {
        $open = $report.EquipOpen[1]
        if ($open.Visible -ne 1) {
            Add-Failure "shot 1 equipment panel was not visible"
        }
        if ($open.Left -gt $PanelLeftInsetMax) {
            Add-Failure ("shot 1 equipment panel left edge is at $($open.Left), want within " +
                "$PanelLeftInsetMax px of the left edge")
        }
        if ($open.EndX -ge ($open.ViewportW / 2.0)) {
            Add-Failure ("shot 1 equipment panel ends at $($open.EndX), want left of viewport " +
                "centre $($open.ViewportW / 2.0)")
        }
        Write-Host ("==> client: equipment panel open on the left (x=$($open.Left)..$($open.EndX) " +
            "in viewport $($open.ViewportW))")
    }

    # AC2: after equip, worn holds axe and bag does not.
    if (-not $report.Inventory.ContainsKey(2)) {
        Add-Failure "client reported no inventory for shot 2"
    } elseif ($report.Inventory[2].Occupied -ne 0) {
        Add-Failure ("shot 2 bag holds $($report.Inventory[2].Occupied) item(s), want 0 after equip")
    }
    if (-not $report.Worn.ContainsKey(2)) {
        Add-Failure "client reported no worn state for shot 2"
    } elseif ($report.Worn[2].Kind -ne $AxeKind) {
        Add-Failure ("shot 2 weapon slot holds '$($report.Worn[2].Kind)', want '$AxeKind'")
    } else {
        Write-Host "==> client: weapon slot shows $AxeKind after equip"
    }

    # AC3: after unequip, worn empty and bag has axe again.
    if (-not $report.Worn.ContainsKey(3)) {
        Add-Failure "client reported no worn state for shot 3"
    } elseif (-not [string]::IsNullOrEmpty($report.Worn[3].Kind)) {
        Add-Failure ("shot 3 weapon slot still holds '$($report.Worn[3].Kind)', want empty")
    }
    $bagAfter = $null
    if ($report.Slots.ContainsKey(3)) { $bagAfter = $report.Slots[3] }
    if ($null -eq $bagAfter -or -not $bagAfter.ContainsKey($AxeBagSlot)) {
        Add-Failure "shot 3 bag slot $AxeBagSlot does not show the axe after unequip"
    } elseif ($bagAfter[$AxeBagSlot] -ne $AxeKind) {
        Add-Failure ("shot 3 bag slot $AxeBagSlot holds '$($bagAfter[$AxeBagSlot])', want '$AxeKind'")
    } else {
        Write-Host "==> client: axe returned to bag slot $AxeBagSlot after unequip"
    }

    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) {
        Add-Failure "the server wrote no GAMELOG events"
    }

    $player = $report.Joined
    if ($player -ge 1) {
        $equips = Select-PlayerEvents $events "equip" $player
        if ($equips.Count -ne 1) {
            Add-Failure "the server logged $($equips.Count) equip event(s) for player $player, want 1"
        } else {
            $ev = $equips[0]
            if ([int]$ev.slot -ne $AxeBagSlot) {
                Add-Failure "equip emptied bag slot $($ev.slot), want slot $AxeBagSlot"
            }
            if ([string]$ev.kind -ne $AxeKind) {
                Add-Failure "equip moved kind '$($ev.kind)', want '$AxeKind'"
            }
            if ([string]$ev.worn -ne $WeaponWorn) {
                Add-Failure "equip wore slot '$($ev.worn)', want '$WeaponWorn'"
            }
            Write-Host "==> server: player $player equipped $AxeKind from slot $AxeBagSlot onto $WeaponWorn"
        }

        $unequips = Select-PlayerEvents $events "unequip" $player
        if ($unequips.Count -ne 1) {
            Add-Failure "the server logged $($unequips.Count) unequip event(s) for player $player, want 1"
        } else {
            $ev = $unequips[0]
            if ([string]$ev.worn -ne $WeaponWorn) {
                Add-Failure "unequip named worn '$($ev.worn)', want '$WeaponWorn'"
            }
            if ([string]$ev.kind -ne $AxeKind) {
                Add-Failure "unequip moved kind '$($ev.kind)', want '$AxeKind'"
            }
            if ([int]$ev.slot -ne $AxeBagSlot) {
                Add-Failure "unequip returned to bag slot $($ev.slot), want slot $AxeBagSlot"
            }
            Write-Host "==> server: player $player unequipped $AxeKind from $WeaponWorn into slot $AxeBagSlot"
        }

        foreach ($kind in @("equip_rejected", "unequip_rejected")) {
            $rejected = Select-PlayerEvents $events $kind $player
            if ($rejected.Count -gt 0) {
                Add-Failure "the server logged $($rejected.Count) $kind event(s) for player $player"
            }
        }
    }
} catch {
    Add-Failure "$($_.Exception.Message)"
} finally {
    if ($null -ne $server) {
        if ($server.HasExited) {
            Add-Failure "marqued exited on its own with code $($server.ExitCode)"
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
            Add-Failure "marqued wrote to stderr: $firstLine"
        }
    }
    Show-File "marqued event log ($serverOut)" $serverOut
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "evidence (screenshots, client log, server event log): $OutDir"
if ($failures.Count -eq 0) {
    Write-Host "EQUIP DEMO OK"
    exit 0
}
Write-Host "EQUIP DEMO FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1
