[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-enemy-party"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 90,
    [switch] $OutgoingOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "marque-demo-lib.ps1")

$QuestId = "slay_imps"

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-enemy-party-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"

$server = $null
$clients = @()
$failures = New-MarqueDemoFailures

function Read-ClientReport([string] $path) {
    $report = @{
        Joined = -1
        Role = ""
        Failures = New-Object System.Collections.Generic.List[string]
        Done = $false
        Accepted = $false
        PartyId = -1
        PartyMembers = 0
        OutgoingOnly = $false
        RemoteSwings = New-Object System.Collections.Generic.List[object]
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
            '^DEMO party (\d+) members=(\d+)\s*$' {
                $report.PartyId = [int]$Matches[1]
                $report.PartyMembers = [int]$Matches[2]
            }
            '^DEMO outgoing_only role=(\S+)\s*$' { $report.OutgoingOnly = $true }
            '^DEMO remote_swing actor=(\d+) target=(\d+) amount=(\d+) crit=(true|false) miss=(true|false)\s*$' {
                $report.RemoteSwings.Add([pscustomobject]@{
                    Actor = [int]$Matches[1]
                    Target = [int]$Matches[2]
                    Amount = [int]$Matches[3]
                    Crit = [bool]::Parse($Matches[4])
                    Miss = [bool]::Parse($Matches[5])
                })
            }
        }
    }
    return $report
}

try {
    $null = Initialize-MarqueEvidenceDir -OutDir $OutDir -SourceScript "scripts/enemy_party_demo.ps1"

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

    Write-Host "==> starting marqued on a free port (-admin; knight kit via client /give)"
    $server = Start-Process -FilePath $binary `
        -ArgumentList @("-addr", "127.0.0.1:0", "-admin") `
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
            "--enemy-party-shots", ('"' + $spec.Prefix + '"'),
            "--enemy-party-role", $spec.Role
        )
        if ($OutgoingOnly) { $godotArgs += "--outgoing-only" }
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

    Wait-MarqueClients -Clients $clients -TimeoutSeconds $ClientTimeoutSeconds

    foreach ($client in $clients) {
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
        if (-not $OutgoingOnly -and -not $report.Accepted) {
            Add-Failure "client-$($client.Name) never reported DEMO accepted $QuestId active"
        }
        if ($OutgoingOnly -and -not $report.OutgoingOnly) {
            Add-Failure "client-$($client.Name) never completed the outgoing-only proof"
        }
        if ($report.PartyId -lt 1 -or $report.PartyMembers -lt 2) {
            Add-Failure "client-$($client.Name) party id=$($report.PartyId) members=$($report.PartyMembers), want party with 2"
        }
        # PNG artifact only (ARM-289); DEMO + GAMELOG are the proof.
        $shot = "$($client.Prefix)_1.png"
        if (Test-Path $shot) {
            $size = (Get-Item $shot).Length
            Write-Host "==> $shot ($size bytes, artifact)"
        }
    }

    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) {
        Add-Failure "the server wrote no GAMELOG events"
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

    if ($OutgoingOnly) {
        $leader = $reports["a"]
        $member = $reports["b"]
        $remote = @($member.RemoteSwings | Where-Object {
            $_.Actor -eq $leader.Joined -and $_.Actor -ne $member.Joined
        })
        if ($remote.Count -lt 1) {
            Add-Failure "observer client-b ingested no nonlocal swing from client-a"
        } else {
            $knownTargets = @($remote | Where-Object { $_.Target -gt 0 })
            if ($knownTargets.Count -lt 1) {
                Add-Failure "observer client-b remote swing named no target"
            }
        }
        $observerFct = @(Select-String -Path $clients[1].Stdout -Pattern '^DEMO fct ' -ErrorAction SilentlyContinue)
        if ($observerFct.Count -ne 0) {
            Add-Failure "observer client-b rendered $($observerFct.Count) floating combat text line(s) for nonlocal traffic"
        }
        $qualifyingHits = @($events | Where-Object {
            $_.ev -eq "attack_hit" -and $_.PSObject.Properties.Name -contains "player" -and
            [int]$_.player -eq $leader.Joined -and $_.PSObject.Properties.Name -contains "target"
        })
        if ($qualifyingHits.Count -lt 1) {
            Add-Failure "server logged no player attack_hit from client-a"
        } elseif ($remote.Count -gt 0) {
            $target = $remote[0].Target
            $matchingHits = @($qualifyingHits | Where-Object { [int]$_.target -eq $target })
            if ($matchingHits.Count -lt 1) {
                Add-Failure "observer remote target $target has no matching server attack_hit"
            }
        }
    } else {
        foreach ($player in $ids) {
            $accepted = Select-Events $events "quest_accepted" $player
            if ($accepted.Count -lt 1) {
                Add-Failure "player $player has no quest_accepted"
            } elseif ([string]$accepted[0].quest -ne $QuestId) {
                Add-Failure "player $player quest_accepted '$($accepted[0].quest)', want $QuestId"
            }
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

Write-MarqueDemoResult `
    -OkMarker $(if ($OutgoingOnly) { "OUTGOING ONLY DEMO OK" } else { "ENEMY PARTY DEMO OK" }) `
    -FailMarker "ENEMY PARTY DEMO FAILED" `
    -EvidenceLine "evidence (screenshots, client logs, server event log): $OutDir"
