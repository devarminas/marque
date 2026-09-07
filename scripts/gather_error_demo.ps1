[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-gather-error"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RefusalText = "usable tool not equipped"
$LogsKind = "logs"
$WoodcuttingSkill = "woodcutting"
$LumberjackClass = "lumberjack"
$KitSeeds = @("1.0,0.8,forester_cap", "2.0,0.8,forester_shirt", "3.0,0.8,forester_trousers", "4.0,0.8,lumberjack_axe")
$LingerFloorMsec = 3000
$LingerCeilingMsec = 9000
$BandTop = 612
$BandBottom = 644
$BandLeft = 400
$BandRight = 880
$ControlLeft = 0
$ControlRight = 400
$ControlCeilingFraction = 0.02

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-gather-error-" + [guid]::NewGuid().ToString("n"))
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

function Compare-Band([string] $left, [string] $right, [int] $x0, [int] $x1) {
    Add-Type -AssemblyName System.Drawing
    $a = [System.Drawing.Bitmap]::FromFile($left)
    $b = [System.Drawing.Bitmap]::FromFile($right)
    try {
        if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) {
            throw "frames differ in size: $left is $($a.Width)x$($a.Height), $right is $($b.Width)x$($b.Height)"
        }
        $rect = New-Object System.Drawing.Rectangle 0, 0, $a.Width, $a.Height
        $format = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        $mode = [System.Drawing.Imaging.ImageLockMode]::ReadOnly
        $la = $a.LockBits($rect, $mode, $format)
        $lb = $b.LockBits($rect, $mode, $format)
        $count = $la.Stride * $a.Height
        $stride = $la.Stride
        $bytesA = New-Object byte[] $count
        $bytesB = New-Object byte[] $count
        [System.Runtime.InteropServices.Marshal]::Copy($la.Scan0, $bytesA, 0, $count)
        [System.Runtime.InteropServices.Marshal]::Copy($lb.Scan0, $bytesB, 0, $count)
        $a.UnlockBits($la)
        $b.UnlockBits($lb)

        $top = [Math]::Max(0, [Math]::Min($BandTop, $a.Height - 1))
        $bottom = [Math]::Max($top + 1, [Math]::Min($BandBottom, $a.Height))
        $left_x = [Math]::Max(0, [Math]::Min($x0, $a.Width - 1))
        $right_x = [Math]::Max($left_x + 1, [Math]::Min($x1, $a.Width))

        $sampled = 0
        $differing = 0
        for ($y = $top; $y -lt $bottom; $y++) {
            $row = $y * $stride
            for ($x = $left_x; $x -lt $right_x; $x++) {
                $i = $row + $x * 4
                $sampled++
                if ($bytesA[$i] -ne $bytesB[$i] -or
                    $bytesA[$i + 1] -ne $bytesB[$i + 1] -or
                    $bytesA[$i + 2] -ne $bytesB[$i + 2]) {
                    $differing++
                }
            }
        }
        return @{ Sampled = $sampled; Differing = $differing }
    } finally {
        $a.Dispose()
        $b.Dispose()
    }
}

function Read-ClientReport([string] $path) {
    $report = @{
        Joined = -1
        Failures = New-Object System.Collections.Generic.List[string]
        Done = $false
        ErrorText = $null
        ClearedMsec = -1
        LeftClickGathers = -1
        Gathered = $null
        Class = $null
        Shots = @{}
        HudText = @{}
        Slots = @{}
        Nodes = @{}
    }
    if (-not (Test-Path $path)) { return $report }
    foreach ($line in Get-Content -Path $path) {
        $text = $line.Trim()
        switch -Regex ($text) {
            '^DEMO joined (\d+)$' { $report.Joined = [int]$Matches[1] }
            '^DEMO FAIL (.+)$' { $report.Failures.Add($Matches[1].Trim()) }
            '^DEMO done$' { $report.Done = $true }
            '^DEMO errortext (.*)$' { $report.ErrorText = $Matches[1] }
            '^DEMO errorcleared (\d+)$' { $report.ClearedMsec = [int]$Matches[1] }
            '^DEMO leftclickgathers (\d+)$' { $report.LeftClickGathers = [int]$Matches[1] }
            '^DEMO gathered (\S+) (\d+)$' { $report.Gathered = $Matches[1] }
            '^DEMO class ([a-z_]+)$' { $report.Class = $Matches[1] }
            '^DEMO shot (\d+) (.+)$' { $report.Shots[[int]$Matches[1]] = $Matches[2].Trim() }
            '^DEMO errorhud (\d+) ?(.*)$' { $report.HudText[[int]$Matches[1]] = $Matches[2] }
            '^DEMO invslot (\d+) (\d+) (\S+)$' {
                $shot = [int]$Matches[1]
                if (-not $report.Slots.ContainsKey($shot)) { $report.Slots[$shot] = @{} }
                $report.Slots[$shot][[int]$Matches[2]] = $Matches[3]
            }
            '^DEMO node (\d+) (\d+) (\S+) (\S+) (\S+) (\S+)$' {
                $shot = [int]$Matches[1]
                if (-not $report.Nodes.ContainsKey($shot)) { $report.Nodes[$shot] = @{} }
                $report.Nodes[$shot][[int]$Matches[2]] = $Matches[6]
            }
        }
    }
    return $report
}

try {
    if (Test-Path $OutDir) {
        $stale = @(Get-ChildItem -LiteralPath $OutDir -Force)
        if ($stale.Count -gt 0) {
            if (-not (Test-Path $evidenceMarker)) {
                throw ("$OutDir is not empty and carries no .marque-evidence marker; refusing to run.")
            }
            Write-Host "==> clearing $($stale.Count) leftover item(s) from $OutDir"
            $stale | Remove-Item -Recurse -Force
        }
    } else {
        New-Item -ItemType Directory -Path $OutDir | Out-Null
    }
    Set-Content -LiteralPath $evidenceMarker -Value "gather_error_demo.ps1" -Encoding utf8

    Write-Host "==> building marqued"
    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build exited $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    Write-Host "==> warming the Godot import cache"
    $warm = Start-Process -FilePath $Godot -Wait -PassThru -NoNewWindow `
        -ArgumentList @("--headless", "--path", ('"' + $clientDir + '"'), "--quit-after", "20") `
        -RedirectStandardOutput (Join-Path $OutDir "warm.stdout.log") `
        -RedirectStandardError (Join-Path $OutDir "warm.stderr.log")
    if ($warm.ExitCode -ne 0) {
        throw "the Godot warm-up run exited $($warm.ExitCode)"
    }

    Write-Host "==> starting marqued on a free port"
    $serverArgs = @("-addr", "127.0.0.1:0")
    foreach ($seed in $KitSeeds) { $serverArgs += @("-item", $seed) }
    $server = Start-Process -FilePath $binary `
        -ArgumentList $serverArgs `
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

    $prefix = Join-Path $OutDir "a"
    $stdout = Join-Path $OutDir "client-a.stdout.log"
    $stderr = Join-Path $OutDir "client-a.stderr.log"
    Write-Host "==> launching the client"
    $client = Start-Process -FilePath $Godot -NoNewWindow -PassThru `
        -ArgumentList @(
            "--path", ('"' + $clientDir + '"'),
            "--position", "40,60",
            "--",
            "--server", $url,
            "--gather-error-shots", ('"' + $prefix + '"')
        ) `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $client.Handle

    if ($client.WaitForExit($ClientTimeoutSeconds * 1000)) {
        $client.WaitForExit()
    } else {
        Add-Failure "the client did not finish within $ClientTimeoutSeconds seconds"
        Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
    }

    Show-File "client stdout" $stdout
    Show-File "client stderr" $stderr

    if ($client.HasExited -and $client.ExitCode -ne 0) {
        Add-Failure "the client exited $($client.ExitCode)"
    }

    $report = Read-ClientReport $stdout
    foreach ($reason in $report.Failures) { Add-Failure "the client reported DEMO FAIL: $reason" }
    if ($report.Joined -lt 1) { Add-Failure "the client never reported the id it joined as" }
    if (-not $report.Done) { Add-Failure "the client never reported 'DEMO done'" }

    foreach ($index in 1, 2, 3) {
        $shot = "${prefix}_$index.png"
        if (-not (Test-Path $shot)) {
            Add-Failure "the client never wrote $shot"
            continue
        }
        $size = (Get-Item $shot).Length
        Write-Host "==> $shot ($size bytes)"
        if ($size -lt 4096) { Add-Failure "$shot is only $size bytes; that is not a frame" }
    }

    if ($report.ErrorText -ne $RefusalText) {
        Add-Failure "the client rendered '$($report.ErrorText)' for a no-kit gather, want '$RefusalText'"
    }
    if ($report.HudText.ContainsKey(1)) {
        if ($report.HudText[1] -ne $RefusalText) {
            Add-Failure "shot 1 was captured with hud text '$($report.HudText[1])', want '$RefusalText'"
        }
    } else {
        Add-Failure "the client never reported the hud text at shot 1"
    }
    if ($report.HudText.ContainsKey(2)) {
        if (-not [string]::IsNullOrEmpty($report.HudText[2])) {
            Add-Failure "shot 2 still shows '$($report.HudText[2])'; the refusal never cleared"
        }
    } else {
        Add-Failure "the client never reported the hud text at shot 2"
    }
    if ($report.HudText.ContainsKey(3)) {
        if (-not [string]::IsNullOrEmpty($report.HudText[3])) {
            Add-Failure "shot 3 shows '$($report.HudText[3])' after a successful gather"
        }
    } else {
        Add-Failure "the client never reported the hud text at shot 3"
    }

    if ($report.ClearedMsec -lt 0) {
        Add-Failure "the client never reported how long the refusal stayed on screen"
    } elseif ($report.ClearedMsec -lt $LingerFloorMsec -or $report.ClearedMsec -gt $LingerCeilingMsec) {
        Add-Failure "the refusal cleared after $($report.ClearedMsec)ms, want $LingerFloorMsec..$LingerCeilingMsec"
    }

    if ($report.LeftClickGathers -ne 0) {
        Add-Failure "a left click on the tree sent $($report.LeftClickGathers) gather intent(s), want 0"
    }
    if ($report.Class -ne $LumberjackClass) {
        Add-Failure "the client never reported the $LumberjackClass class, it reported '$($report.Class)'"
    }
    if ($report.Gathered -ne $LogsKind) {
        Add-Failure "the client never reported gathering $LogsKind"
    }
    if ($report.Slots.ContainsKey(3)) {
        if ($LogsKind -notin $report.Slots[3].Values) {
            Add-Failure "shot 3 bag holds no $LogsKind"
        }
    } else {
        Add-Failure "shot 3 reported no bag slots"
    }
    if ($report.Nodes.ContainsKey(3)) {
        $states = @($report.Nodes[3].Values)
        if ("depleted" -notin $states) {
            Add-Failure "shot 3 shows no depleted node; states were $($states -join ', ')"
        }
    } else {
        Add-Failure "shot 3 reported no resource nodes"
    }

    if ((Test-Path "${prefix}_1.png") -and (Test-Path "${prefix}_2.png")) {
        $band = Compare-Band "${prefix}_1.png" "${prefix}_2.png" $BandLeft $BandRight
        $control = Compare-Band "${prefix}_1.png" "${prefix}_2.png" $ControlLeft $ControlRight
        $bandFraction = if ($band.Sampled -gt 0) { $band.Differing / [double]$band.Sampled } else { 0 }
        $controlFraction = if ($control.Sampled -gt 0) { $control.Differing / [double]$control.Sampled } else { 0 }
        Write-Host ("==> label band: {0} of {1} pixel(s) differ ({2:P2}); control band left of it: {3} of {4} ({5:P2})" -f `
            $band.Differing, $band.Sampled, $bandFraction, $control.Differing, $control.Sampled, $controlFraction)
        if ($band.Sampled -le 0 -or $control.Sampled -le 0) {
            Add-Failure "a band comparison read zero pixels; it proves nothing"
        } else {
            if ($band.Differing -le 0) {
                Add-Failure "shot 1 and shot 2 are pixel-identical where the label sits; no text was drawn there"
            }
            if ($controlFraction -gt $ControlCeilingFraction) {
                Add-Failure ("the control band left of the label also changed ({0:P2}); the frames differ for some reason other than the text" -f $controlFraction)
            }
        }
    }

    $events = Read-GameLog $serverOut
    if ($events.Count -eq 0) { Add-Failure "the server event log has no GAMELOG lines" }

    $player = $report.Joined
    if ($player -ge 1) {
        $rejected = Select-PlayerEvents $events "gather_rejected" $player
        if ($rejected.Count -ne 1) {
            Add-Failure "the server logged $($rejected.Count) gather_rejected event(s) for player $player, want 1"
        } else {
            $reason = $rejected[0].reason
            if ($reason -ne "needs_class") {
                Add-Failure "gather_rejected carried reason '$reason', want 'needs_class'"
            }
        }

        $accepted = Select-PlayerEvents $events "gather" $player
        if ($accepted.Count -ne 1) {
            Add-Failure "the server accepted $($accepted.Count) gather intent(s) from player $player, want 1"
        }

        $resolved = Select-PlayerEvents $events "gather_resolved" $player
        if ($resolved.Count -ne 1) {
            Add-Failure "the server resolved $($resolved.Count) gather(s) for player $player, want 1"
        } elseif ($resolved[0].kind -ne $LogsKind) {
            Add-Failure "gather_resolved yielded '$($resolved[0].kind)', want '$LogsKind'"
        }

        $xp = Select-PlayerEvents $events "skill_xp" $player
        if ($xp.Count -lt 1) {
            Add-Failure "the server granted no skill_xp for the completed gather"
        } elseif ($xp[0].skill -ne $WoodcuttingSkill) {
            Add-Failure "skill_xp named skill '$($xp[0].skill)', want '$WoodcuttingSkill'"
        }
    }

    foreach ($kind in @("gather_no_room", "gather_lost")) {
        $bad = @($events | Where-Object { $_.ev -eq $kind })
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
    Write-Host "GATHER ERROR DEMO OK"
    exit 0
}
Write-Host "GATHER ERROR DEMO FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1
