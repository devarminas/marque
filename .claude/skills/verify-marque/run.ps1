<#
.SYNOPSIS
    Generic scripted two-client session against a freshly built marqued, leaving
    every observable behind in one evidence directory. Structural guarantees
    only; behavioural assertions are the caller's job, made against the
    evidence.

.DESCRIPTION
    Generalises scripts/two_client_demo.ps1 without replacing it: that script is
    the fixed M0 milestone scenario with its assertions baked in, this one runs
    the same rig — build marqued, warm the Godot caches, serve on a kernel-picked
    port, drive two real windowed clients through the client's own flag path —
    and then stops, leaving judgment to whoever asked for the run.

    Evidence directory contents (path printed at the end, never deleted here):

        server.stdout.ndjson    the GAMELOG event log, the server's ground truth
        server.stderr.log       must be empty on a healthy run
        client-a.stdout.log     DEMO joined/clicked/shot/pos/done lines
        client-b.stdout.log
        client-a.stderr.log
        client-b.stderr.log
        a_1.png .. a_4.png      client a's four self-captures
        b_1.png .. b_4.png      client b's

    VERIFY HARNESS OK asserts structure only: the server announced itself,
    outlived the clients, and kept a silent stderr; each client joined, printed
    DEMO done, exited 0, and wrote four plausible frames. It is deliberately NOT
    a behavioural verdict — a server that lied about movement would still earn
    it. Catching that is the caller's assertions on the evidence files, per
    SKILL.md's proof standards.

.PARAMETER ClickA
.PARAMETER ClickB
    Viewport-fraction ground click for each client. Client a clicks in phase 1,
    client b in phase 2, mirroring the demo. Pass "" to make that client never
    walk; it still watches and captures all four shots.

.PARAMETER EvidenceDir
    Where the evidence lands. Defaults to a fresh timestamped directory under
    $env:TEMP\marque-verify. Created if absent, never cleaned up.
#>
[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $EvidenceDir = "",
    [string] $ClickA = "0.30,0.72",
    [string] $ClickB = "0.70,0.72",
    [int] $ReadyTimeoutSeconds = 20,
    [int] $ClientTimeoutSeconds = 120,
    [int] $WarmupTimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# .claude/skills/verify-marque -> skills -> .claude -> repo root.
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$serverDir = Join-Path $repo "server"
$clientDir = Join-Path $repo "client"

if ([string]::IsNullOrWhiteSpace($EvidenceDir)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $EvidenceDir = Join-Path $env:TEMP ("marque-verify\" + $stamp + "-" + [guid]::NewGuid().ToString("n").Substring(0, 6))
}
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null

# Scratch state lives apart from the evidence so cleanup can never eat a proof.
$work = Join-Path $env:TEMP ("marque-verify-work-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $work | Out-Null

$binary = Join-Path $work "marqued.exe"
$serverOut = Join-Path $EvidenceDir "server.stdout.ndjson"
$serverErr = Join-Path $EvidenceDir "server.stderr.log"

$server = $null
$failures = New-Object System.Collections.Generic.List[string]

function Get-DemoLine([string] $path, [string] $pattern) {
    if (-not (Test-Path $path)) { return $null }
    foreach ($line in Get-Content -Path $path) {
        if ($line -match $pattern) { return $Matches }
    }
    return $null
}

try {
    Write-Host "==> building marqued"
    Push-Location $serverDir
    try {
        & go build -o $binary ./cmd/marqued
        if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path (Join-Path $clientDir ".godot"))) {
        # Fresh checkout. Without the editor cache, headless Godot fails to parse
        # any script naming a global class_name and the errors point everywhere
        # but here (NOTES.md, "Godot authoring traps").
        Write-Host "==> client\.godot is absent; building the editor cache once"
        $editorWarm = Start-Process -FilePath $Godot `
            -ArgumentList @("--headless", "--path", ('"' + $clientDir + '"'), "--editor", "--quit") `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput (Join-Path $work "editor-warm.stdout.log") `
            -RedirectStandardError (Join-Path $work "editor-warm.stderr.log")
        $null = $editorWarm.Handle
        if (-not $editorWarm.WaitForExit($WarmupTimeoutSeconds * 1000)) {
            Stop-Process -Id $editorWarm.Id -Force -ErrorAction SilentlyContinue
            throw "the editor cache warm-up did not finish within $WarmupTimeoutSeconds seconds"
        }
        $editorWarm.WaitForExit()
        if ($editorWarm.ExitCode -ne 0) { throw "the editor cache warm-up exited $($editorWarm.ExitCode)" }
    }

    Write-Host "==> warming the Godot import cache"
    # Whichever process imports first writes client\.godot, and two doing it at
    # once race; one headless pass before the parallel launch settles it.
    $warm = Start-Process -FilePath $Godot `
        -ArgumentList @("--headless", "--path", ('"' + $clientDir + '"'), "--quit-after", "20") `
        -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput (Join-Path $work "warm.stdout.log") `
        -RedirectStandardError (Join-Path $work "warm.stderr.log")
    if ($warm.ExitCode -ne 0) { throw "the Godot import warm-up exited $($warm.ExitCode)" }

    Write-Host "==> starting marqued on a free port"
    $server = Start-Process -FilePath $binary `
        -ArgumentList "-addr", "127.0.0.1:0" `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
    # Touching Handle caches it; without this a -PassThru process object reads
    # its ExitCode back as empty once the process is gone.
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
        Start-Sleep -Milliseconds 25
    }
    if (-not $address) {
        throw "marqued did not announce a listening address within $ReadyTimeoutSeconds seconds"
    }
    $url = "ws://$address/ws"
    Write-Host "==> marqued listening, url $url"
    Write-Host "==> evidence directory: $EvidenceDir"

    $clients = @(
        @{ Label = "a"; Click = $ClickA; Phase = 1; Position = "40,60" },
        @{ Label = "b"; Click = $ClickB; Phase = 2; Position = "700,140" }
    )

    $running = @()
    foreach ($client in $clients) {
        $prefix = Join-Path $EvidenceDir $client.Label
        $stdout = Join-Path $EvidenceDir ("client-" + $client.Label + ".stdout.log")
        $stderr = Join-Path $EvidenceDir ("client-" + $client.Label + ".stderr.log")
        $godotArgs = @(
            "--path", ('"' + $clientDir + '"'),
            "--position", $client.Position,
            "--",
            "--server", $url,
            "--shots", ('"' + $prefix + '"')
        )
        if (-not [string]::IsNullOrWhiteSpace($client.Click)) {
            $godotArgs += @("--click", $client.Click, "--phase", $client.Phase.ToString())
        }

        Write-Host "==> launching client $($client.Label)"
        $process = Start-Process -FilePath $Godot -ArgumentList $godotArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null = $process.Handle
        $running += @{
            Label = $client.Label
            Process = $process
            Stdout = $stdout
            Prefix = $prefix
        }
    }

    foreach ($client in $running) {
        if ($client.Process.WaitForExit($ClientTimeoutSeconds * 1000)) {
            # The parameterless overload as well: the timed one returns without
            # caching ExitCode on a -PassThru process.
            $client.Process.WaitForExit()
        } else {
            $failures.Add("client $($client.Label) did not finish within $ClientTimeoutSeconds seconds")
            Stop-Process -Id $client.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($client in $running) {
        $label = $client.Label
        if ($client.Process.HasExited) {
            $code = $client.Process.ExitCode
            if ($null -eq $code) {
                $failures.Add("client $label's exit code could not be read")
            } elseif ($code -ne 0) {
                $failures.Add("client $label exited $code")
            }
        }

        # The exit code alone lets a client that quit early pass: DEMO done is
        # printed only after every capture was written, and DEMO joined is the
        # id every behavioural assertion will need.
        $joined = Get-DemoLine $client.Stdout '^DEMO joined (\d+)\s*$'
        if ($null -eq $joined) {
            $failures.Add("client $label never reported the id it joined as (no 'DEMO joined' line)")
        } else {
            Write-Host "==> client $label joined as player $($joined[1])"
        }
        $done = Get-DemoLine $client.Stdout '^DEMO done\s*$'
        if ($null -eq $done) {
            $failures.Add("client $label never reported 'DEMO done'")
        }

        foreach ($index in 1, 2, 3, 4) {
            $shot = "$($client.Prefix)_$index.png"
            if (-not (Test-Path $shot)) {
                $failures.Add("client $label never wrote $shot")
                continue
            }
            $size = (Get-Item $shot).Length
            if ($size -lt 4096) { $failures.Add("$shot is only $size bytes; that is not a frame") }
        }
    }
} catch {
    $failures.Add("$($_.Exception.Message) [$($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())]")
} finally {
    if ($null -ne $server) {
        if ($server.HasExited) {
            # A server that died after the last frame the clients awaited would
            # otherwise be reported as a clean run.
            $failures.Add("marqued exited on its own with code $($server.ExitCode); it must outlive the clients")
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
            $failures.Add("marqued wrote to stderr: $firstLine")
        }
    }
    # Scratch only. The evidence directory is the deliverable and is never
    # touched here.
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "evidence: $EvidenceDir"
if ($failures.Count -eq 0) {
    Write-Host "VERIFY HARNESS OK"
    exit 0
}
Write-Host "VERIFY HARNESS FAILED"
foreach ($failure in $failures) { Write-Host "  - $failure" }
exit 1
