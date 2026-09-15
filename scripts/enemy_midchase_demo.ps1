[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-enemy-midchase"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "marque-demo-lib.ps1")

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-enemy-midchase-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $OutDir "server.stdout.ndjson"
$serverErr = Join-Path $OutDir "server.stderr.log"
$clientOut = Join-Path $OutDir "client.stdout.log"
$clientErr = Join-Path $OutDir "client.stderr.log"
$prefix = Join-Path $OutDir "c"

$server = $null
$failures = New-MarqueDemoFailures

function Read-ClientReport([string] $path) {
    $report = @{
        Joined = -1
        Failures = New-Object System.Collections.Generic.List[string]
        Done = $false
        Midchase = $false
        MidchaseNpcLines = New-Object System.Collections.Generic.List[string]
        MidchaseAnimLines = New-Object System.Collections.Generic.List[string]
        MidchaseWalking = 0
        MidchaseHasPath = 0
        NpcByShot = @{}
    }
    if (-not (Test-Path $path)) { return $report }
    $inMidchase = $false
    $currentShot = -1
    foreach ($line in Get-Content -Path $path) {
        switch -Regex ($line) {
            '^DEMO joined (\d+)\s*$' { $report.Joined = [int]$Matches[1] }
            '^DEMO FAIL (.+)$' { $report.Failures.Add($Matches[1].Trim()) }
            '^DEMO done\s*$' { $report.Done = $true }
            '^DEMO midchase\s*$' {
                $report.Midchase = $true
                $inMidchase = $true
            }
            '^DEMO shot (\d+) (.+)$' {
                $shot = [int]$Matches[1]
                $currentShot = $shot
                if ($shot -ne 2) { $inMidchase = $false }
            }
            '^DEMO npc (\d+) (\S+) ([-\d.]+) ([-\d.]+) walking=([01]) has_path=([01])\s*$' {
                $npcId = [int]$Matches[1]
                $kind = $Matches[2]
                $x = [double]$Matches[3]
                $z = [double]$Matches[4]
                $walking = [int]$Matches[5]
                $hasPath = [int]$Matches[6]
                if ($currentShot -ge 1) {
                    if (-not $report.NpcByShot.ContainsKey($currentShot)) {
                        $report.NpcByShot[$currentShot] = @{}
                    }
                    $report.NpcByShot[$currentShot][$npcId] = @{
                        Kind = $kind; X = $x; Z = $z; Walking = $walking; HasPath = $hasPath
                    }
                }
                if ($inMidchase) {
                    $report.MidchaseNpcLines.Add($line)
                    if ($walking -eq 1) { $report.MidchaseWalking++ }
                    if ($hasPath -eq 1) { $report.MidchaseHasPath++ }
                }
            }
            '^DEMO anim (\d+) (\S+)\s*$' {
                if ($inMidchase) { $report.MidchaseAnimLines.Add($line) }
            }
        }
    }
    return $report
}

function Test-MidchaseMotion($report) {
    if ($report.MidchaseWalking -ge 1 -or $report.MidchaseHasPath -ge 1) {
        return $true
    }
    if (-not $report.NpcByShot.ContainsKey(1) -or -not $report.NpcByShot.ContainsKey(2)) {
        return $false
    }
    $before = $report.NpcByShot[1]
    $after = $report.NpcByShot[2]
    foreach ($id in $after.Keys) {
        if (-not $before.ContainsKey($id)) { continue }
        if ($after[$id].Kind -ne "imp") { continue }
        $dx = $after[$id].X - $before[$id].X
        $dz = $after[$id].Z - $before[$id].Z
        if ([math]::Sqrt(($dx * $dx) + ($dz * $dz)) -ge 0.5) {
            return $true
        }
    }
    return $false
}

try {
    $null = Initialize-MarqueEvidenceDir -OutDir $OutDir -SourceScript "scripts/enemy_midchase_demo.ps1"

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

    Write-Host "==> launching midchase client"
    $client = Start-Process -FilePath $Godot -NoNewWindow -PassThru `
        -ArgumentList @(
            "--path", ('"' + $clientDir + '"'),
            "--position", "40,60",
            "--",
            "--server", $url,
            "--enemy-midchase-shots", ('"' + $prefix + '"')
        ) `
        -RedirectStandardOutput $clientOut -RedirectStandardError $clientErr
    $null = $client.Handle

    if ($client.WaitForExit($ClientTimeoutSeconds * 1000)) {
        $client.WaitForExit()
    } else {
        Add-Failure "client did not finish within $ClientTimeoutSeconds seconds"
        Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
    }

    Show-File "client stdout" $clientOut
    Show-File "client stderr" $clientErr

    if ($client.HasExited) {
        $code = $client.ExitCode
        if ($null -eq $code) {
            Add-Failure "client exit code could not be read"
        } elseif ($code -ne 0) {
            Add-Failure "client exited $code"
        }
    }

    $report = Read-ClientReport $clientOut
    if ($report.Joined -lt 1) { Add-Failure "client never reported DEMO joined" }
    foreach ($reason in $report.Failures) { Add-Failure "client reported DEMO FAIL: $reason" }
    if (-not $report.Done) { Add-Failure "client never reported DEMO done" }
    if (-not $report.Midchase) { Add-Failure "client never reported DEMO midchase" }
    if ($report.MidchaseNpcLines.Count -lt 1) {
        Add-Failure "mid-chase wrote 0 DEMO npc lines"
    } else {
        Write-Host ("==> mid-chase DEMO npc lines={0} walking={1} has_path={2}" -f `
            $report.MidchaseNpcLines.Count, $report.MidchaseWalking, $report.MidchaseHasPath)
    }
    if ($report.MidchaseAnimLines.Count -lt 1) {
        Add-Failure "mid-chase wrote 0 DEMO anim lines"
    }
    if (-not (Test-MidchaseMotion $report)) {
        Add-Failure "mid-chase lacked walking=1, has_path=1, or >=0.5u imp displacement"
    } else {
        Write-Host ("==> mid-chase motion ok (walking={0} has_path={1})" -f `
            $report.MidchaseWalking, $report.MidchaseHasPath)
    }

    # PNG artifacts only (ARM-289); DEMO + GAMELOG are the proof.
    foreach ($index in 1, 2) {
        $shot = "${prefix}_$index.png"
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

Write-MarqueDemoResult `
    -OkMarker "ENEMY MIDCHASE DEMO OK" `
    -FailMarker "ENEMY MIDCHASE DEMO FAILED" `
    -EvidenceLine "evidence (screenshots, client logs, server event log): $OutDir"
