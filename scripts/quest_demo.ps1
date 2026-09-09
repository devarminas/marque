[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-quest"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SticksKind = "sticks"
$QuestId = "bring_a_stick"
$KitBagSlot = 0
$RewardKinds = @(
    "prospector_jacket",
    "prospector_boots",
    "prospector_helm",
    "prospector_legs",
    "pickaxe"
)

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-quest-" + [guid]::NewGuid().ToString("n"))
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
        Accepted = $false
        Complete = $false
        QuestLogs = @{}
        StickSlot = -1
        GiveNpc = -1
        GiveSlot = -1
    }
    if (-not (Test-Path $path)) { return $report }
    foreach ($line in Get-Content -Path $path) {
        switch -Regex ($line) {
            '^DEMO joined (\d+)\s*$' { $report.Joined = [int]$Matches[1] }
            '^DEMO FAIL (.+)$' { $report.Failures.Add($Matches[1].Trim()) }
            '^DEMO done\s*$' { $report.Done = $true }
            '^DEMO stickslot (\d+)\s*$' { $report.StickSlot = [int]$Matches[1] }
            '^DEMO accepted (\S+) active\s*$' {
                if ($Matches[1] -eq $QuestId) { $report.Accepted = $true }
            }
            '^DEMO complete (\S+)\s*$' {
                if ($Matches[1] -eq $QuestId) { $report.Complete = $true }
            }
            '^DEMO give (\d+) (\d+)\s*$' {
                $report.GiveNpc = [int]$Matches[1]
                $report.GiveSlot = [int]$Matches[2]
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
            '^DEMO questlog (\d+) empty\s*$' {
                $report.QuestLogs[[int]$Matches[1]] = @("empty")
            }
            '^DEMO questlog (\d+) (\S+) (.+) (active|complete)\s*$' {
                $shot = [int]$Matches[1]
                if (-not $report.QuestLogs.ContainsKey($shot)) {
                    $report.QuestLogs[$shot] = New-Object System.Collections.Generic.List[string]
                }
                $report.QuestLogs[$shot].Add("$($Matches[2]) $($Matches[4])")
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
        -Value "Evidence from scripts/quest_demo.ps1. Its next run empties this directory."

    Write-Host "==> building marqued"
    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    Write-Host "==> warming the Godot import cache"
    $godotDir = Join-Path $clientDir ".godot"
    if (-not (Test-Path $godotDir)) {
        $editorWarm = Start-Process -FilePath $Godot `
            -ArgumentList @("--headless", "--path", ('"' + $clientDir + '"'), "--editor", "--quit") `
            -NoNewWindow -PassThru -Wait `
            -RedirectStandardOutput (Join-Path $OutDir "warm-editor.stdout.log") `
            -RedirectStandardError (Join-Path $OutDir "warm-editor.stderr.log")
        if ($editorWarm.ExitCode -ne 0) {
            throw "the Godot editor warm-up run exited $($editorWarm.ExitCode)"
        }
    }
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
        -ArgumentList "-addr", "127.0.0.1:0", "-join-kit", $SticksKind `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
    $null = $server.Handle

    $address = $null
    $started = $null
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($server.HasExited) {
            throw "marqued exited with code $($server.ExitCode) before it announced an address"
        }
        if (Test-Path $serverOut) {
            $line = Select-String -Path $serverOut -Pattern '"ev":"server_started"' -List
            if ($null -ne $line) {
                $started = ($line.Line -replace '^GAMELOG ', '') | ConvertFrom-Json
                if ($line.Line -match '"addr":"([^"]+)"') { $address = $Matches[1]; break }
                throw "server_started carried no addr: $($line.Line)"
            }
        }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $address) { throw "marqued never logged server_started within $ReadyTimeoutSeconds seconds" }
    $url = "ws://$address/ws"
    Write-Host "==> marqued listening at $url (pid $($server.Id))"

    $joinKit = @($started.join_kit)
    if ($joinKit.Count -ne 1 -or $joinKit[0] -ne $SticksKind) {
        Add-Failure "server_started.join_kit is [$($joinKit -join ',')], want [$SticksKind]"
    } else {
        Write-Host "==> server: -join-kit put $SticksKind in every joining player's bag"
    }

    $prefix = Join-Path $OutDir "client"
    $stdout = Join-Path $OutDir "client.stdout.log"
    $stderr = Join-Path $OutDir "client.stderr.log"
    $godotArgs = @(
        "--path", ('"' + $clientDir + '"'),
        "--position", "40,60",
        "--",
        "--server", $url,
        "--quest-shots", ('"' + $prefix + '"')
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
    if (-not $report.Accepted) {
        Add-Failure "client never reported DEMO accepted $QuestId active"
    }
    if (-not $report.Complete) {
        Add-Failure "client never reported DEMO complete $QuestId"
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

    if (-not $report.Slots.ContainsKey(1) -or -not (Test-HasKind $report.Slots[1] $SticksKind)) {
        Add-Failure "shot 1 bag does not show the seeded $SticksKind"
    }
    if (-not $report.QuestLogs.ContainsKey(2)) {
        Add-Failure "client never reported questlog for shot 2"
    } elseif (@($report.QuestLogs[2]) -notcontains "$QuestId active") {
        Add-Failure "shot 2 questlog did not report $QuestId active"
    }

    if (-not $report.Slots.ContainsKey(3)) {
        Add-Failure "client reported no inventory slots for shot 3"
    } else {
        $after = $report.Slots[3]
        if (Test-HasKind $after $SticksKind) {
            Add-Failure "shot 3 bag still holds $SticksKind after give"
        }
        foreach ($kind in $RewardKinds) {
            if (-not (Test-HasKind $after $kind)) {
                Add-Failure "shot 3 bag missing reward kind $kind"
            }
        }
        Write-Host "==> client: miner reward kinds present after give; sticks gone"
    }

    if (-not $report.QuestLogs.ContainsKey(3)) {
        Add-Failure "client never reported questlog for shot 3"
    } elseif (@($report.QuestLogs[3]) -notcontains "$QuestId complete") {
        Add-Failure "shot 3 questlog did not report $QuestId complete"
    } else {
        Write-Host "==> client: quest_log restatement shows $QuestId complete"
    }

    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) {
        Add-Failure "the server wrote no GAMELOG events"
    }

    $player = $report.Joined
    if ($player -ge 1) {
        $seeded = Select-PlayerEvents $events "join_seeded" $player
        if ($seeded.Count -ne 1) {
            Add-Failure "the server logged $($seeded.Count) join_seeded event(s) for player $player, want 1"
        } else {
            $ev = $seeded[0]
            if ([string]$ev.kind -ne $SticksKind) {
                Add-Failure "join_seeded named kind '$($ev.kind)', want '$SticksKind'"
            }
            if ([int]$ev.slot -ne $KitBagSlot) {
                Add-Failure "join_seeded filled bag slot $($ev.slot), want slot $KitBagSlot"
            }
            Write-Host "==> server: the join kit gave player $player $SticksKind in slot $KitBagSlot"
        }

        $accepted = Select-PlayerEvents $events "quest_accepted" $player
        if ($accepted.Count -ne 1) {
            Add-Failure "the server logged $($accepted.Count) quest_accepted event(s) for player $player, want 1"
        } else {
            $ev = $accepted[0]
            if ([string]$ev.quest -ne $QuestId) {
                Add-Failure "quest_accepted named quest '$($ev.quest)', want '$QuestId'"
            }
            Write-Host "==> server: player $player accepted $QuestId"
        }

        $completed = Select-PlayerEvents $events "quest_completed" $player
        if ($completed.Count -ne 1) {
            Add-Failure "the server logged $($completed.Count) quest_completed event(s) for player $player, want 1"
        } else {
            $ev = $completed[0]
            if ([string]$ev.quest -ne $QuestId) {
                Add-Failure "quest_completed named quest '$($ev.quest)', want '$QuestId'"
            }
            if ([string]$ev.consume -ne $SticksKind) {
                Add-Failure "quest_completed consume '$($ev.consume)', want '$SticksKind'"
            }
            if ([int]$ev.rewards -ne $RewardKinds.Count) {
                Add-Failure "quest_completed rewards $($ev.rewards), want $($RewardKinds.Count)"
            }
            Write-Host "==> server: player $player completed $QuestId and consumed $SticksKind"
        }

        foreach ($kind in @("talk_rejected", "dialog_option_rejected", "give_rejected")) {
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
    Write-Host "QUEST DEMO OK"
    exit 0
}
Write-Host "QUEST DEMO FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1
