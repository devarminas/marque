<#
.SYNOPSIS
    The M4 milestone on screen and in the server's ledger: two windowed clients
    equip the join-kit axe, race the seeded tree for one logs yield, and the
    winner crafts logs→sticks via use. Exits 0 only when GAMELOG shows one
    gather_resolved and one gather_lost for that depletion, one use
    logs→sticks, and both clients print DEMO done with three screenshots each.

.PARAMETER Godot
    The Godot 4 executable. Defaults to $env:GODOT, then "godot" on PATH.

.PARAMETER OutDir
    Evidence directory. Default `$env:TEMP\marque-gather-craft`. Emptied at the
    start of each run when it carries this script's `.marque-evidence` marker.
#>
[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-gather-craft"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 150
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AxeKind = "axe"
$WeaponWorn = "weapon"
$LogsKind = "logs"
$SticksKind = "sticks"
$TreeKind = "tree"
$SeedTreeX = 5.0
$SeedTreeZ = 0.0
$CoordEpsilon = 0.05

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-gather-craft-" + [guid]::NewGuid().ToString("n"))
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
        Outcome = -1
        SeedNode = $null
        Shots = @{}
        Inventory = @{}
        Slots = @{}
        Worn = @{}
        Nodes = @{}
    }
    if (-not (Test-Path $path)) { return $report }
    foreach ($line in Get-Content -Path $path) {
        switch -Regex ($line) {
            '^DEMO joined (\d+)\s*$' { $report.Joined = [int]$Matches[1] }
            '^DEMO FAIL (.+)$' { $report.Failures.Add($Matches[1].Trim()) }
            '^DEMO done\s*$' { $report.Done = $true }
            '^DEMO outcome (\d+)\s*$' { $report.Outcome = [int]$Matches[1] }
            '^DEMO seednode (\d+) (\S+) (-?[0-9.eE+-]+) (-?[0-9.eE+-]+) (\S+)\s*$' {
                $report.SeedNode = @{
                    Id = [int]$Matches[1]
                    Kind = $Matches[2]
                    X = [double]$Matches[3]
                    Z = [double]$Matches[4]
                    State = $Matches[5]
                }
            }
            '^DEMO shot (\d+) (.+)$' { $report.Shots[[int]$Matches[1]] = $Matches[2].Trim() }
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
            '^DEMO node (\d+) (\d+) (\S+) (-?[0-9.eE+-]+) (-?[0-9.eE+-]+) (\S+)\s*$' {
                $shot = [int]$Matches[1]
                if (-not $report.Nodes.ContainsKey($shot)) { $report.Nodes[$shot] = @{} }
                $report.Nodes[$shot][[int]$Matches[2]] = @{
                    Kind = $Matches[3]
                    X = [double]$Matches[4]
                    Z = [double]$Matches[5]
                    State = $Matches[6]
                }
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

function Test-HasKind($slots, [string] $kind) {
    if ($null -eq $slots) { return $false }
    foreach ($key in $slots.Keys) {
        if ($slots[$key] -eq $kind) { return $true }
    }
    return $false
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
        -Value "Evidence from scripts/gather_craft_demo.ps1. Its next run empties this directory."

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

    $running = @()
    foreach ($spec in @(@{ Label = "a"; Position = "40,60" }, @{ Label = "b"; Position = "700,140" })) {
        $prefix = Join-Path $OutDir $spec.Label
        $stdout = Join-Path $OutDir ("client-" + $spec.Label + ".stdout.log")
        $stderr = Join-Path $OutDir ("client-" + $spec.Label + ".stderr.log")
        Write-Host "==> launching client $($spec.Label)"
        $process = Start-Process -FilePath $Godot -NoNewWindow -PassThru `
            -ArgumentList @(
                "--path", ('"' + $clientDir + '"'),
                "--position", $spec.Position,
                "--",
                "--server", $url,
                "--gather-craft-shots", ('"' + $prefix + '"')
            ) `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null = $process.Handle
        $running += @{
            Label = $spec.Label; Process = $process; Stdout = $stdout; Stderr = $stderr
            Prefix = $prefix; Report = $null
        }
    }

    foreach ($client in $running) {
        if ($client.Process.WaitForExit($ClientTimeoutSeconds * 1000)) {
            $client.Process.WaitForExit()
        } else {
            Add-Failure "client $($client.Label) did not finish within $ClientTimeoutSeconds seconds"
            Stop-Process -Id $client.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($client in $running) {
        Show-File "client $($client.Label) stdout" $client.Stdout
        Show-File "client $($client.Label) stderr" $client.Stderr

        if ($client.Process.HasExited) {
            $code = $client.Process.ExitCode
            if ($null -eq $code) {
                Add-Failure "client $($client.Label) exit code could not be read"
            } elseif ($code -ne 0) {
                Add-Failure "client $($client.Label) exited $code"
            }
        }

        $client.Report = Read-ClientReport $client.Stdout
        if ($client.Report.Joined -lt 1) {
            Add-Failure "client $($client.Label) never reported the id it joined as"
        }
        if ($client.Report.Failures.Count -gt 0) {
            foreach ($reason in $client.Report.Failures) {
                Add-Failure "client $($client.Label) reported DEMO FAIL: $reason"
            }
        }
        if (-not $client.Report.Done) {
            Add-Failure "client $($client.Label) never reported 'DEMO done'"
        }

        foreach ($index in 1, 2, 3) {
            $shot = "$($client.Prefix)_$index.png"
            if (-not (Test-Path $shot)) {
                Add-Failure "client $($client.Label) never wrote $shot"
                continue
            }
            $size = (Get-Item $shot).Length
            Write-Host "==> $shot ($size bytes)"
            if ($size -lt 4096) { Add-Failure "$shot is only $size bytes; that is not a frame" }
        }

        if ($null -eq $client.Report.SeedNode) {
            Add-Failure "client $($client.Label) never reported the seeded tree"
        } else {
            $seed = $client.Report.SeedNode
            if ($seed.Kind -ne $TreeKind) {
                Add-Failure "client $($client.Label) seeded kind '$($seed.Kind)', want '$TreeKind'"
            }
            if ([math]::Abs($seed.X - $SeedTreeX) -gt $CoordEpsilon -or [math]::Abs($seed.Z - $SeedTreeZ) -gt $CoordEpsilon) {
                Add-Failure ("client $($client.Label) tree at ($($seed.X),$($seed.Z)), want " +
                    "($SeedTreeX,$SeedTreeZ)")
            }
        }

        if (-not $client.Report.Worn.ContainsKey(1) -or $client.Report.Worn[1].Kind -ne $AxeKind) {
            Add-Failure "client $($client.Label) shot 1 does not show a worn $AxeKind"
        }
    }

    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) {
        Add-Failure "the server wrote no GAMELOG events"
    }

    $players = @()
    foreach ($client in $running) {
        if ($client.Report.Joined -ge 1) { $players += $client.Report.Joined }
    }
    $players = @($players | Select-Object -Unique)
    if ($players.Count -ne 2) {
        Add-Failure "expected two distinct joined player ids, got $($players.Count)"
    }

    foreach ($player in $players) {
        $equips = Select-Events $events "equip" $player
        if ($equips.Count -ne 1) {
            Add-Failure "the server logged $($equips.Count) equip event(s) for player $player, want 1"
        } elseif ([string]$equips[0].kind -ne $AxeKind -or [string]$equips[0].worn -ne $WeaponWorn) {
            Add-Failure "player $player equip was kind='$($equips[0].kind)' worn='$($equips[0].worn)'"
        }
    }

    $nodeId = -1
    foreach ($client in $running) {
        if ($null -ne $client.Report.SeedNode) {
            $nodeId = [int]$client.Report.SeedNode.Id
            break
        }
    }

    $resolved = Select-Events $events "gather_resolved"
    $lost = Select-Events $events "gather_lost"
    $depleted = Select-Events $events "node_depleted"
    if ($resolved.Count -ne 1) {
        Add-Failure "the server resolved $($resolved.Count) gather(s), want exactly 1"
    }
    if ($lost.Count -ne 1) {
        Add-Failure "the server recorded $($lost.Count) lost gather(s), want exactly 1"
    }
    if ($depleted.Count -ne 1) {
        Add-Failure "the server depleted $($depleted.Count) node(s), want exactly 1"
    }
    if ($resolved.Count -eq 1 -and $lost.Count -eq 1) {
        $winner = [int]$resolved[0].player
        $loser = [int]$lost[0].player
        if ($winner -eq $loser) {
            Add-Failure "gather_resolved and gather_lost named the same player $winner"
        }
        if ($players.Count -eq 2 -and (@($winner, $loser) | Sort-Object) -join "," -ne (@($players | Sort-Object) -join ",")) {
            Add-Failure "gather winner/loser {$winner,$loser} are not the joined pair {$($players -join ',')}"
        }
        if ($nodeId -gt 0) {
            if ([int]$resolved[0].node -ne $nodeId -or [int]$lost[0].node -ne $nodeId) {
                Add-Failure "gather events named nodes $($resolved[0].node)/$($lost[0].node), want $nodeId"
            }
        }
        if ([string]$resolved[0].kind -ne $LogsKind) {
            Add-Failure "gather_resolved kind '$($resolved[0].kind)', want '$LogsKind'"
        }
        Write-Host "==> server: player $winner won logs; player $loser lost the contested gather"

        $uses = Select-Events $events "use" $winner
        if ($uses.Count -ne 1) {
            Add-Failure "the server logged $($uses.Count) use event(s) for winner $winner, want 1"
        } else {
            if ([string]$uses[0].from -ne $LogsKind -or [string]$uses[0].to -ne $SticksKind) {
                Add-Failure ("use crafted '{0}'->'{1}', want {2}->{3}" -f $uses[0].from, $uses[0].to, $LogsKind, $SticksKind)
            } else {
                Write-Host ("==> server: player {0} crafted {1}->{2}" -f $winner, $LogsKind, $SticksKind)
            }
        }
        $loserUses = Select-Events $events "use" $loser
        if ($loserUses.Count -gt 0) {
            Add-Failure "the losing gatherer $loser still logged $($loserUses.Count) use event(s)"
        }

        foreach ($client in $running) {
            $id = $client.Report.Joined
            $label = $client.Label
            if ($id -eq $winner) {
                if ($client.Report.Outcome -ne 1) {
                    Add-Failure "client $label (winner $id) reported outcome $($client.Report.Outcome), want 1"
                }
                if (-not (Test-HasKind $client.Report.Slots[2] $LogsKind)) {
                    Add-Failure "client $label shot 2 bag has no $LogsKind after gather"
                }
                if (-not (Test-HasKind $client.Report.Slots[3] $SticksKind)) {
                    Add-Failure "client $label shot 3 bag has no $SticksKind after craft"
                }
                if (Test-HasKind $client.Report.Slots[3] $LogsKind) {
                    Add-Failure "client $label shot 3 bag still holds $LogsKind after craft"
                }
            } elseif ($id -eq $loser) {
                if ($client.Report.Outcome -ne 0) {
                    Add-Failure "client $label (loser $id) reported outcome $($client.Report.Outcome), want 0"
                }
                if (Test-HasKind $client.Report.Slots[2] $LogsKind) {
                    Add-Failure "client $label shot 2 bag holds $LogsKind despite losing the gather"
                }
                if (Test-HasKind $client.Report.Slots[3] $SticksKind) {
                    Add-Failure "client $label shot 3 bag holds $SticksKind despite losing the gather"
                }
            }

            foreach ($shot in @(2)) {
                if (-not $client.Report.Nodes.ContainsKey($shot)) {
                    Add-Failure "client $label shot $shot reported no resource nodes"
                    continue
                }
                foreach ($nid in $client.Report.Nodes[$shot].Keys) {
                    $state = $client.Report.Nodes[$shot][$nid].State
                    if ($state -ne "depleted") {
                        Add-Failure "client $label shot $shot node $nid state '$state', want depleted"
                    }
                }
            }
        }
    }

    foreach ($kind in @("gather_rejected", "use_rejected", "gather_no_room")) {
        $bad = Select-Events $events $kind
        if ($bad.Count -gt 0) {
            Add-Failure "the server logged $($bad.Count) $kind event(s)"
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
Write-Host "evidence (screenshots, client logs, server event log): $OutDir"
if ($failures.Count -eq 0) {
    Write-Host "GATHER CRAFT DEMO OK"
    exit 0
}
Write-Host "GATHER CRAFT DEMO FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1
