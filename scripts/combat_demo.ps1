<#
.SYNOPSIS
    The M5 milestone on screen and in the server's ledger: two windowed clients,
    A engages B from out of AttackRange, walks in, lands period hits of 10 until
    death, B shows the death overlay, respawns to HP 100, and can act again.
    Exits 0 only when GAMELOG shows the walk-in, ten attack_hit events, death,
    and respawn, and both clients print DEMO done with three screenshots each.

.PARAMETER Godot
    The Godot 4 executable. Defaults to $env:GODOT, then "godot" on PATH.

.PARAMETER OutDir
    Evidence directory. Default `$env:TEMP\marque-combat`. Emptied at the
    start of each run when it carries this script's `.marque-evidence` marker.
#>
[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-combat"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AttackDamage = 10
$MaxHP = 100
$AttackRange = 1.5
$ExpectedHits = [int]($MaxHP / $AttackDamage)

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-combat-" + [guid]::NewGuid().ToString("n"))
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
        Role = ""
        Target = -1
        Failures = New-Object System.Collections.Generic.List[string]
        Done = $false
        Shots = @{}
        Positions = @{}
        HP = @{}
        Dist = @{}
        DeathVisible = @{}
        AttackClick = $false
        Relocate = $false
        RespawnClick = $false
        PostMove = $false
    }
    if (-not (Test-Path $path)) { return $report }
    foreach ($line in Get-Content -Path $path) {
        switch -Regex ($line) {
            '^DEMO joined (\d+)\s*$' { $report.Joined = [int]$Matches[1] }
            '^DEMO role (\S+)\s*$' { $report.Role = $Matches[1] }
            '^DEMO target (\d+)\s*$' { $report.Target = [int]$Matches[1] }
            '^DEMO FAIL (.+)$' { $report.Failures.Add($Matches[1].Trim()) }
            '^DEMO done\s*$' { $report.Done = $true }
            '^DEMO shot (\d+) (.+)$' { $report.Shots[[int]$Matches[1]] = $Matches[2].Trim() }
            '^DEMO pos (\d+) (\d+) (-?[0-9.eE+-]+) (-?[0-9.eE+-]+)\s*$' {
                $shot = [int]$Matches[1]
                if (-not $report.Positions.ContainsKey($shot)) { $report.Positions[$shot] = @{} }
                $report.Positions[$shot][[int]$Matches[2]] = @{
                    X = [double]$Matches[3]; Z = [double]$Matches[4]
                }
            }
            '^DEMO hp (\d+) (\d+) (-?\d+) (-?\d+)\s*$' {
                $shot = [int]$Matches[1]
                if (-not $report.HP.ContainsKey($shot)) { $report.HP[$shot] = @{} }
                $report.HP[$shot][[int]$Matches[2]] = @{
                    HP = [int]$Matches[3]; Max = [int]$Matches[4]
                }
            }
            '^DEMO dist (\d+) (-?[0-9.eE+-]+)\s*$' {
                $report.Dist[[int]$Matches[1]] = [double]$Matches[2]
            }
            '^DEMO deathvisible (\d+) ([01])\s*$' {
                $report.DeathVisible[[int]$Matches[1]] = [int]$Matches[2]
            }
            '^DEMO attackclick ' { $report.AttackClick = $true }
            '^DEMO relocate ' { $report.Relocate = $true }
            '^DEMO respawnclick\s*$' { $report.RespawnClick = $true }
            '^DEMO postmove ' { $report.PostMove = $true }
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
        -Value "Evidence from scripts/combat_demo.ps1. Its next run empties this directory."

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
    foreach ($spec in @(
        @{ Label = "a"; Position = "40,60"; Role = "attacker" },
        @{ Label = "b"; Position = "700,140"; Role = "victim" }
    )) {
        $prefix = Join-Path $OutDir $spec.Label
        $stdout = Join-Path $OutDir ("client-" + $spec.Label + ".stdout.log")
        $stderr = Join-Path $OutDir ("client-" + $spec.Label + ".stderr.log")
        Write-Host "==> launching client $($spec.Label) as $($spec.Role)"
        $process = Start-Process -FilePath $Godot -NoNewWindow -PassThru `
            -ArgumentList @(
                "--path", ('"' + $clientDir + '"'),
                "--position", $spec.Position,
                "--",
                "--server", $url,
                "--combat-shots", ('"' + $prefix + '"'),
                "--combat-role", $spec.Role
            ) `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null = $process.Handle
        $running += @{
            Label = $spec.Label; Role = $spec.Role; Process = $process
            Stdout = $stdout; Stderr = $stderr; Prefix = $prefix; Report = $null
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

    $attacker = $null
    $victim = $null
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
        if ($client.Report.Role -ne $client.Role) {
            Add-Failure "client $($client.Label) role '$($client.Report.Role)', want '$($client.Role)'"
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

        if ($client.Role -eq "attacker") { $attacker = $client }
        if ($client.Role -eq "victim") { $victim = $client }
    }

    if ($null -eq $attacker -or $null -eq $victim) {
        Add-Failure "could not resolve attacker and victim clients"
    } else {
        if (-not $attacker.Report.AttackClick) {
            Add-Failure "attacker never reported DEMO attackclick"
        }
        if (-not $victim.Report.Relocate) {
            Add-Failure "victim never reported DEMO relocate"
        }
        if (-not $victim.Report.RespawnClick) {
            Add-Failure "victim never reported DEMO respawnclick"
        }
        if (-not $victim.Report.PostMove) {
            Add-Failure "victim never reported DEMO postmove after respawn"
        }

        if (-not $victim.Report.DeathVisible.ContainsKey(2) -or $victim.Report.DeathVisible[2] -ne 1) {
            Add-Failure "victim shot 2 does not report death overlay visible"
        }
        if (-not $victim.Report.DeathVisible.ContainsKey(3) -or $victim.Report.DeathVisible[3] -ne 0) {
            Add-Failure "victim shot 3 does not report death overlay hidden"
        }

        foreach ($client in @($attacker, $victim)) {
            if (-not $client.Report.Dist.ContainsKey(1) -or $client.Report.Dist[1] -le $AttackRange) {
                Add-Failure ("client $($client.Label) shot 1 distance {0} is not outside AttackRange {1}" -f `
                    $(if ($client.Report.Dist.ContainsKey(1)) { $client.Report.Dist[1] } else { "missing" }), $AttackRange)
            }
        }

        $victimId = $victim.Report.Joined
        if ($victim.Report.HP.ContainsKey(2)) {
            if (-not $victim.Report.HP[2].ContainsKey($victimId) -or $victim.Report.HP[2][$victimId].HP -ne 0) {
                Add-Failure "victim shot 2 self HP is not 0"
            }
        } else {
            Add-Failure "victim shot 2 reported no DEMO hp lines"
        }
        if ($victim.Report.HP.ContainsKey(3)) {
            if (-not $victim.Report.HP[3].ContainsKey($victimId) -or $victim.Report.HP[3][$victimId].HP -ne $MaxHP) {
                Add-Failure "victim shot 3 self HP is not $MaxHP"
            }
        } else {
            Add-Failure "victim shot 3 reported no DEMO hp lines"
        }
    }

    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) {
        Add-Failure "the server wrote no GAMELOG events"
    }

    if ($null -ne $attacker -and $null -ne $victim -and $attacker.Report.Joined -ge 1 -and $victim.Report.Joined -ge 1) {
        $attackerId = $attacker.Report.Joined
        $victimId = $victim.Report.Joined

        $attacks = Select-Events $events "attack" $attackerId
        if ($attacks.Count -lt 1) {
            Add-Failure "the server logged $($attacks.Count) attack event(s) for attacker $attackerId, want at least 1"
        } elseif ([int]$attacks[0].target -ne $victimId) {
            Add-Failure "attack target $($attacks[0].target), want victim $victimId"
        } else {
            Write-Host "==> server: player $attackerId attacked player $victimId"
        }

        $paths = Select-Events $events "path_assigned" $attackerId
        $attackTick = if ($attacks.Count -ge 1) { [int64]$attacks[0].t } else { -1 }
        $walkPath = $null
        foreach ($path in $paths) {
            if ($attackTick -ge 0 -and [int64]$path.t -ge $attackTick) {
                $walkPath = $path
                break
            }
        }
        if ($null -eq $walkPath) {
            Add-Failure "attacker $attackerId has no path_assigned at or after the attack; the walk-in claim failed"
        } else {
            Write-Host "==> server: attacker path_assigned at tick $($walkPath.t) after attack"
        }

        $hits = Select-Events $events "attack_hit"
        if ($hits.Count -ne $ExpectedHits) {
            Add-Failure "the server logged $($hits.Count) attack_hit event(s), want $ExpectedHits"
        } else {
            $expectedHP = $MaxHP
            foreach ($hit in $hits) {
                if ([int]$hit.player -ne $attackerId -or [int]$hit.target -ne $victimId) {
                    Add-Failure "attack_hit players $($hit.player)/$($hit.target), want $attackerId/$victimId"
                }
                if ([int]$hit.damage -ne $AttackDamage) {
                    Add-Failure "attack_hit damage $($hit.damage), want $AttackDamage"
                }
                $expectedHP -= $AttackDamage
                if ($expectedHP -lt 0) { $expectedHP = 0 }
                if ([int]$hit.target_hp -ne $expectedHP) {
                    Add-Failure "attack_hit target_hp $($hit.target_hp), want $expectedHP"
                }
            }
            Write-Host "==> server: $ExpectedHits hits of $AttackDamage down to 0"
        }

        $deaths = Select-Events $events "death" $victimId
        if ($deaths.Count -ne 1) {
            Add-Failure "the server logged $($deaths.Count) death event(s) for victim $victimId, want 1"
        } elseif ([int]$deaths[0].killer -ne $attackerId) {
            Add-Failure "death killer $($deaths[0].killer), want attacker $attackerId"
        }

        $respawns = Select-Events $events "respawn" $victimId
        if ($respawns.Count -ne 1) {
            Add-Failure "the server logged $($respawns.Count) respawn event(s) for victim $victimId, want 1"
        } else {
            Write-Host "==> server: victim $victimId respawned"
        }

        $postMoves = Select-Events $events "move_to" $victimId
        $respawnTick = if ($respawns.Count -ge 1) { [int64]$respawns[0].t } else { -1 }
        $acted = $false
        foreach ($move in $postMoves) {
            if ($respawnTick -ge 0 -and [int64]$move.t -ge $respawnTick) {
                $acted = $true
                break
            }
        }
        if (-not $acted) {
            Add-Failure "victim $victimId has no move_to at or after respawn; cannot prove they can act again"
        } else {
            Write-Host "==> server: victim moved after respawn"
        }

        foreach ($kind in @("attack_rejected", "respawn_rejected")) {
            $bad = Select-Events $events $kind
            if ($bad.Count -gt 0) {
                Add-Failure "the server logged $($bad.Count) $kind event(s)"
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
Write-Host "evidence (screenshots, client logs, server event log): $OutDir"
if ($failures.Count -eq 0) {
    Write-Host "COMBAT DEMO OK"
    exit 0
}
Write-Host "COMBAT DEMO FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1
