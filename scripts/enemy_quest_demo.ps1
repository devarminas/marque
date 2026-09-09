[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-enemy-quest"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 210
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$QuestId = "slay_imps"
$NeedKills = 5
$CampId = "starter_town_imps"
$ImpKind = "imp"
$KnightKit = @(
    "plate_helm",
    "plate_chest",
    "plate_legs",
    "sword",
    "shield"
)
$RewardKinds = @(
    "plate_chest",
    "plate_helm",
    "plate_legs",
    "shield",
    "sword"
)

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-enemy-quest-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
$evidenceMarker = Join-Path $OutDir ".marque-evidence"

$server = $null
$clients = @()
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
        Role = ""
        Failures = New-Object System.Collections.Generic.List[string]
        Done = $false
        Accepted = $false
        Complete = $false
        KillsReady = $false
        PartyId = -1
        PartyMembers = 0
        Shots = @{}
        QuestLogs = @{}
        Slots = @{}
    }
    if (-not (Test-Path $path)) { return $report }
    foreach ($line in Get-Content -Path $path) {
        switch -Regex ($line) {
            '^DEMO joined (\d+)\s*$' { $report.Joined = [int]$Matches[1] }
            '^DEMO role (\S+)\s*$' { $report.Role = $Matches[1] }
            '^DEMO FAIL (.+)$' { $report.Failures.Add($Matches[1].Trim()) }
            '^DEMO done\s*$' { $report.Done = $true }
            '^DEMO accepted (\S+) active\s*$' {
                if ($Matches[1] -eq $QuestId) { $report.Accepted = $true }
            }
            '^DEMO complete (\S+)\s*$' {
                if ($Matches[1] -eq $QuestId) { $report.Complete = $true }
            }
            '^DEMO killsready (\S+)\s*$' {
                if ($Matches[1] -eq $QuestId) { $report.KillsReady = $true }
            }
            '^DEMO party (\d+) members=(\d+)\s*$' {
                $report.PartyId = [int]$Matches[1]
                $report.PartyMembers = [int]$Matches[2]
            }
            '^DEMO shot (\d+) (.+)$' { $report.Shots[[int]$Matches[1]] = $Matches[2].Trim() }
            '^DEMO invslot (\d+) (\d+) (\S+)\s*$' {
                $shot = [int]$Matches[1]
                if (-not $report.Slots.ContainsKey($shot)) { $report.Slots[$shot] = @{} }
                $report.Slots[$shot][[int]$Matches[2]] = $Matches[3]
            }
            '^DEMO questlog (\d+) (\S+) .+ (active|complete) \| (.+)$' {
                $shot = [int]$Matches[1]
                if (-not $report.QuestLogs.ContainsKey($shot)) {
                    $report.QuestLogs[$shot] = New-Object System.Collections.Generic.List[string]
                }
                $report.QuestLogs[$shot].Add("$($Matches[2]) $($Matches[3]) | $($Matches[4])")
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
        -Value "Evidence from scripts/enemy_quest_demo.ps1. Its next run empties this directory."

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
    $joinArgs = @()
    foreach ($kind in $KnightKit) {
        $joinArgs += @("-join-kit", $kind)
    }
    $server = Start-Process -FilePath $binary `
        -ArgumentList (@("-addr", "127.0.0.1:0") + $joinArgs) `
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

    $specs = @(
        @{ Name = "a"; Role = "leader"; Pos = "40,60"; Prefix = (Join-Path $OutDir "a") },
        @{ Name = "b"; Role = "member"; Pos = "700,60"; Prefix = (Join-Path $OutDir "b") }
    )

    foreach ($spec in $specs) {
        $stdout = Join-Path $OutDir ("client-{0}.stdout.log" -f $spec.Name)
        $stderr = Join-Path $OutDir ("client-{0}.stderr.log" -f $spec.Name)
        $godotArgs = @(
            "--path", ('"' + $clientDir + '"'),
            "--position", $spec.Pos,
            "--",
            "--server", $url,
            "--enemy-quest-shots", ('"' + $spec.Prefix + '"'),
            "--enemy-quest-role", $spec.Role
        )
        Write-Host "==> launching client-$($spec.Name) as $($spec.Role)"
        $proc = Start-Process -FilePath $Godot -ArgumentList $godotArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null = $proc.Handle
        $clients += @{
            Name = $spec.Name
            Role = $spec.Role
            Prefix = $spec.Prefix
            Process = $proc
            Stdout = $stdout
            Stderr = $stderr
        }
    }

    $deadline = (Get-Date).AddSeconds($ClientTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $alive = @($clients | Where-Object { -not $_.Process.HasExited })
        if ($alive.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    }

    foreach ($client in $clients) {
        if (-not $client.Process.HasExited) {
            Add-Failure "client-$($client.Name) did not finish within $ClientTimeoutSeconds seconds"
            Stop-Process -Id $client.Process.Id -Force -ErrorAction SilentlyContinue
            $client.Process.WaitForExit(5000) | Out-Null
        } else {
            $client.Process.WaitForExit() | Out-Null
        }
        Show-File "client-$($client.Name) stdout" $client.Stdout
        Show-File "client-$($client.Name) stderr" $client.Stderr
        if ($client.Process.HasExited) {
            $code = $client.Process.ExitCode
            if ($null -eq $code) {
                Add-Failure "client-$($client.Name) exit code could not be read"
            } elseif ($code -ne 0) {
                Add-Failure "client-$($client.Name) exited $code"
            }
        }
    }

    $reports = @{}
    foreach ($client in $clients) {
        $report = Read-ClientReport $client.Stdout
        $reports[$client.Name] = $report
        if ($report.Joined -lt 1) {
            Add-Failure "client-$($client.Name) never reported the id it joined as"
        }
        if ($report.Role -ne $client.Role) {
            Add-Failure "client-$($client.Name) role '$($report.Role)', want '$($client.Role)'"
        }
        foreach ($reason in $report.Failures) {
            Add-Failure "client-$($client.Name) DEMO FAIL: $reason"
        }
        if (-not $report.Done) {
            Add-Failure "client-$($client.Name) never reported 'DEMO done'"
        }
        if (-not $report.Accepted) {
            Add-Failure "client-$($client.Name) never reported DEMO accepted $QuestId active"
        }
        if (-not $report.KillsReady) {
            Add-Failure "client-$($client.Name) never reported DEMO killsready $QuestId"
        }
        if (-not $report.Complete) {
            Add-Failure "client-$($client.Name) never reported DEMO complete $QuestId"
        }
        if ($report.PartyId -lt 1 -or $report.PartyMembers -lt 2) {
            Add-Failure "client-$($client.Name) party id=$($report.PartyId) members=$($report.PartyMembers), want party with 2"
        }
        foreach ($index in 1, 2, 3) {
            $shot = "$($client.Prefix)_$index.png"
            if (-not (Test-Path $shot)) {
                Add-Failure "client-$($client.Name) never wrote $shot"
                continue
            }
            $size = (Get-Item $shot).Length
            Write-Host "==> $shot ($size bytes)"
            if ($size -lt 4096) { Add-Failure "$shot is only $size bytes; that is not a frame" }
        }
        if (-not $report.QuestLogs.ContainsKey(1) -or -not (@($report.QuestLogs[1]) -match "^$QuestId active")) {
            Add-Failure "client-$($client.Name) shot 1 questlog missing $QuestId active"
        }
        if (-not $report.QuestLogs.ContainsKey(2) -or -not (@($report.QuestLogs[2]) -match "\(5/5\)")) {
            Add-Failure "client-$($client.Name) shot 2 questlog missing $QuestId (5/5)"
        }
        if (-not $report.QuestLogs.ContainsKey(3) -or -not (@($report.QuestLogs[3]) -match "^$QuestId complete")) {
            Add-Failure "client-$($client.Name) shot 3 questlog missing $QuestId complete"
        }
        if (-not $report.Slots.ContainsKey(3)) {
            Add-Failure "client-$($client.Name) reported no inventory slots for shot 3"
        } else {
            foreach ($kind in $RewardKinds) {
                if (-not (Test-HasKind $report.Slots[3] $kind)) {
                    Add-Failure "client-$($client.Name) shot 3 bag missing reward kind $kind"
                }
            }
        }
    }

    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) {
        Add-Failure "the server wrote no GAMELOG events"
    }

    $despawns = Select-Events $events "npc_despawned"
    $impDespawns = @($despawns | Where-Object { [string]$_.kind -eq $ImpKind })
    if ($impDespawns.Count -lt $NeedKills) {
        Add-Failure "npc_despawned imp events=$($impDespawns.Count), want >= $NeedKills"
    } else {
        Write-Host "==> server: $($impDespawns.Count) imp npc_despawned event(s)"
    }
    $campDespawns = @($impDespawns | Where-Object {
        $_.PSObject.Properties.Name -contains "camp" -and [string]$_.camp -eq $CampId
    })
    if ($campDespawns.Count -lt 1) {
        Add-Failure "no npc_despawned events named camp $CampId"
    } else {
        Write-Host "==> server: $($campDespawns.Count) camp $CampId despawn(s)"
    }

    $joined = Select-Events $events "party_joined"
    if ($joined.Count -lt 1) {
        Add-Failure "the server logged 0 party_joined event(s)"
    } else {
        Write-Host "==> server: $($joined.Count) party_joined event(s)"
    }

    $ids = @()
    foreach ($name in @("a", "b")) {
        if ($reports.ContainsKey($name) -and $reports[$name].Joined -ge 1) {
            $ids += $reports[$name].Joined
        }
    }
    $ids = @($ids | Select-Object -Unique)

    foreach ($player in $ids) {
        $accepted = Select-Events $events "quest_accepted" $player
        if ($accepted.Count -lt 1) {
            Add-Failure "player $player has no quest_accepted"
        } elseif ([string]$accepted[0].quest -ne $QuestId) {
            Add-Failure "player $player quest_accepted '$($accepted[0].quest)', want $QuestId"
        }

        $progress = Select-Events $events "quest_kill_progress" $player
        if ($progress.Count -lt $NeedKills) {
            Add-Failure "player $player quest_kill_progress=$($progress.Count), want >= $NeedKills"
        } else {
            $last = $progress[$progress.Count - 1]
            if ([int]$last.count -ne $NeedKills -or [int]$last.need -ne $NeedKills) {
                Add-Failure "player $player final progress count=$($last.count)/$($last.need), want $NeedKills/$NeedKills"
            } else {
                Write-Host "==> server: player $player reached $QuestId $NeedKills/$NeedKills"
            }
        }

        $completed = Select-Events $events "quest_completed" $player
        if ($completed.Count -ne 1) {
            Add-Failure "player $player quest_completed=$($completed.Count), want 1"
        } elseif ([string]$completed[0].quest -ne $QuestId) {
            Add-Failure "player $player quest_completed '$($completed[0].quest)', want $QuestId"
        } else {
            Write-Host "==> server: player $player completed $QuestId"
        }
    }

    # Party membership must exist before/during kill credit.
    if ($joined.Count -ge 1 -and $ids.Count -ge 2) {
        $firstJoinTick = [int64]$joined[0].t
        $progressAll = Select-Events $events "quest_kill_progress"
        $early = @($progressAll | Where-Object { [int64]$_.t -lt $firstJoinTick })
        if ($early.Count -gt 0) {
            Add-Failure "quest_kill_progress appeared before party_joined (tick $($early[0].t) < $firstJoinTick)"
        } else {
            Write-Host "==> server: all quest_kill_progress events are at or after party_joined"
        }
        # Both party members must receive credit for at least one shared kill tick.
        $byTick = @{}
        foreach ($ev in $progressAll) {
            $tick = [string]$ev.t
            if (-not $byTick.ContainsKey($tick)) { $byTick[$tick] = New-Object System.Collections.Generic.List[int] }
            $byTick[$tick].Add([int]$ev.player)
        }
        $shared = $false
        foreach ($tick in $byTick.Keys) {
            $players = @($byTick[$tick] | Select-Object -Unique)
            if ($players.Count -ge 2) { $shared = $true; break }
        }
        if (-not $shared) {
            Add-Failure "no quest_kill_progress tick credited both party members"
        } else {
            Write-Host "==> server: at least one kill credited both party members"
        }
    }

    foreach ($kind in @("party_invite_rejected", "party_accept_rejected", "talk_rejected", "dialog_option_rejected")) {
        $rejected = Select-Events $events $kind
        if ($rejected.Count -gt 0) {
            Add-Failure "the server logged $($rejected.Count) $kind event(s)"
        }
    }
} catch {
    Add-Failure "$($_.Exception.Message)"
} finally {
    foreach ($client in $clients) {
        if ($null -ne $client.Process -and -not $client.Process.HasExited) {
            Stop-Process -Id $client.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
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
    Write-Host "ENEMY QUEST DEMO OK"
    exit 0
}
Write-Host "ENEMY QUEST DEMO FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1