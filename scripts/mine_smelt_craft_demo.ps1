[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-mine-smelt-craft"),
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "marque-demo-lib.ps1")

$OreKind = "copper_ore"
$BarKind = "copper_bar"
$SticksKind = "sticks"
$SwordKind = "sword"
$RockKind = "rock"
$SeedRockX = 2.0
$SeedRockZ = 3.0
$CoordEpsilon = 0.05
$PickaxeKind = "pickaxe"

$repo = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("marque-mine-smelt-craft-" + [guid]::NewGuid().ToString("n"))
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
        Mined = $false
        Smelted = $false
        Crafted = $false
        SeedNode = $null
        Slots = @{}
        Worn = @{}
    }
    if (-not (Test-Path $path)) { return $report }
    foreach ($line in Get-Content -Path $path) {
        switch -Regex ($line) {
            '^DEMO joined (\d+)\s*$' { $report.Joined = [int]$Matches[1] }
            '^DEMO FAIL (.+)$' { $report.Failures.Add($Matches[1].Trim()) }
            '^DEMO done\s*$' { $report.Done = $true }
            '^DEMO mined ' { $report.Mined = $true }
            '^DEMO smelted ' { $report.Smelted = $true }
            '^DEMO crafted ' { $report.Crafted = $true }
            '^DEMO seednode (\d+) (\S+) (-?[0-9.eE+-]+) (-?[0-9.eE+-]+) (\S+)\s*$' {
                $report.SeedNode = @{
                    Id = [int]$Matches[1]
                    Kind = $Matches[2]
                    X = [double]$Matches[3]
                    Z = [double]$Matches[4]
                    State = $Matches[5]
                }
            }
            '^DEMO invslot (\d+) (\d+) (\S+)\s*$' {
                $shot = [int]$Matches[1]
                if (-not $report.Slots.ContainsKey($shot)) { $report.Slots[$shot] = @{} }
                $report.Slots[$shot][[int]$Matches[2]] = $Matches[3]
            }
            '^DEMO worn (\d+) right hand(?: (\S+))?\s*$' {
                $kind = ""
                if ($Matches.Count -ge 3 -and $Matches[2]) { $kind = $Matches[2] }
                $report.Worn[[int]$Matches[1]] = $kind
            }
        }
    }
    return $report
}

try {
    $null = Initialize-MarqueEvidenceDir -OutDir $OutDir -SourceScript "scripts/mine_smelt_craft_demo.ps1"

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

    Write-Host "==> starting marqued on a free port (-admin; kit via client /give)"
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

    Write-Host "==> launching mine/smelt/craft client"
    $client = Start-Process -FilePath $Godot -NoNewWindow -PassThru `
        -ArgumentList @(
            "--path", ('"' + $clientDir + '"'),
            "--position", "40,60",
            "--",
            "--server", $url,
            "--mine-smelt-craft-shots", ('"' + $prefix + '"')
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
    if (-not $report.Mined) { Add-Failure "missing DEMO mined" }
    if (-not $report.Smelted) { Add-Failure "missing DEMO smelted" }
    if (-not $report.Crafted) { Add-Failure "missing DEMO crafted" }

    if ($null -eq $report.SeedNode) {
        Add-Failure "client never reported the seeded rock"
    } else {
        $seed = $report.SeedNode
        if ($seed.Kind -ne $RockKind) {
            Add-Failure "seeded kind '$($seed.Kind)', want '$RockKind'"
        }
        if ([math]::Abs($seed.X - $SeedRockX) -gt $CoordEpsilon -or [math]::Abs($seed.Z - $SeedRockZ) -gt $CoordEpsilon) {
            Add-Failure "rock at ($($seed.X),$($seed.Z)), want ($SeedRockX,$SeedRockZ)"
        }
    }

    if (-not $report.Worn.ContainsKey(1) -or $report.Worn[1] -ne $PickaxeKind) {
        Add-Failure "shot 1 does not show a worn $PickaxeKind"
    }
    if (-not (Test-HasKind $report.Slots[2] $OreKind)) {
        Add-Failure "shot 2 bag has no $OreKind after mine"
    }
    if (-not (Test-HasKind $report.Slots[3] $BarKind)) {
        Add-Failure "shot 3 bag has no $BarKind after smelt"
    }
    if (Test-HasKind $report.Slots[3] $OreKind) {
        Add-Failure "shot 3 bag still holds $OreKind after smelt"
    }
    if (-not (Test-HasKind $report.Slots[4] $SwordKind)) {
        Add-Failure "shot 4 bag has no $SwordKind after craft"
    }
    if (Test-HasKind $report.Slots[4] $BarKind) {
        Add-Failure "shot 4 bag still holds $BarKind after craft"
    }
    if (Test-HasKind $report.Slots[4] $SticksKind) {
        Add-Failure "shot 4 bag still holds $SticksKind after craft"
    }

    # PNG artifacts only (ARM-289); DEMO inventory lines + GAMELOG are the proof.
    foreach ($index in 1..4) {
        $shot = "${prefix}_$index.png"
        if (Test-Path $shot) {
            $size = (Get-Item $shot).Length
            Write-Host "==> $shot ($size bytes, artifact)"
        }
    }

    $events = Read-GameLog $serverOut
    Write-Host "==> GAMELOG: $($events.Count) event(s) in $serverOut"
    if ($events.Count -eq 0) { Add-Failure "the server wrote no GAMELOG events" }

    $player = $report.Joined
    if ($player -ge 1) {
        $resolved = Select-Events $events "gather_resolved" $player
        if ($resolved.Count -lt 1) {
            Add-Failure "gather_resolved for player $player = $($resolved.Count), want >= 1"
        } elseif ([string]$resolved[0].kind -ne $OreKind) {
            Add-Failure "gather_resolved kind '$($resolved[0].kind)', want '$OreKind'"
        }

        $uses = Select-Events $events "use" $player
        $smelt = @($uses | Where-Object { [string]$_.from -eq $OreKind -and [string]$_.to -eq $BarKind })
        $craft = @($uses | Where-Object {
            ([string]$_.from -eq $BarKind -or [string]$_.from -eq $SticksKind) -and [string]$_.to -eq $SwordKind
        })
        if ($smelt.Count -lt 1) {
            Add-Failure "no use event for $OreKind->$BarKind"
        } else {
            Write-Host "==> server: player $player smelted $OreKind->$BarKind"
        }
        if ($craft.Count -lt 1) {
            Add-Failure "no use event crafting $SwordKind"
        } else {
            Write-Host "==> server: player $player crafted $($craft[0].from)->$SwordKind"
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

Write-MarqueDemoResult `
    -OkMarker "MINE SMELT CRAFT DEMO OK" `
    -FailMarker "MINE SMELT CRAFT DEMO FAILED" `
    -EvidenceLine "evidence (screenshots, client logs, server event log): $OutDir"
