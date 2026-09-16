<#
.SYNOPSIS
    Capture and attach reviewer-facing media for a Marque PR.

.DESCRIPTION
    Complementary to DEMO+GAMELOG proof. A PNG or video that merely exists is
    never a behavioural pass (ARM-289). This helper only produces and surfaces
    human-visible artifacts so a reviewer does not have to launch the client.

    Not a windowed demo: doctor does not scan this file.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("capture-screenshot", "capture-frames", "stitch", "attach")]
    [string] $Command,

    [string] $Out,
    [string] $OutPrefix,
    [int] $Count = 16,
    [int] $IntervalMs = 100,
    [string] $Caption = "",
    [string] $Kind = "",
    [string] $Pr = "auto",
    [string[]] $Files = @(),
    [switch] $Attach,
    [switch] $Mp4,
    [switch] $Gif,
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $Command) {
    Write-Host @"
Usage:
  review-evidence.ps1 capture-screenshot [-Out PATH] [-Attach] [-Pr NUMBER|auto] [-Caption TEXT]
  review-evidence.ps1 capture-frames [-OutPrefix PATH] [-Count N] [-IntervalMs MS] [-Mp4] [-Gif] [-Attach]
  review-evidence.ps1 stitch -OutPrefix PATH [-Mp4] [-Gif]
  review-evidence.ps1 attach -Files FILE[,FILE...] [-Pr NUMBER|auto] [-Caption TEXT] [-Kind KIND]

Markers (last line; require exit 0 as well): REVIEW CAPTURE OK / REVIEW STITCH OK / REVIEW ATTACH OK
PNG/video presence is never behavioural proof (ARM-289).
"@
    exit 0
}

# .cursor/skills/verify-marque -> skills -> .cursor -> repo root.
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$staging = Join-Path ([System.IO.Path]::GetTempPath()) "marque-review-evidence"

function Get-PrNumber {
    param([string] $Spec)
    if ([string]::IsNullOrWhiteSpace($Spec) -or $Spec -eq "auto") {
        $n = gh pr view --json number --jq .number
        if ([string]::IsNullOrWhiteSpace($n)) {
            throw "no open PR for this branch (pass -Pr NUMBER)"
        }
        return $n.Trim()
    }
    return $Spec
}

function Assert-Absolute([string] $Path, [string] $Flag) {
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "$Flag must be an absolute path, got $Path"
    }
}

function Invoke-WindowedGodot {
    param([string[]] $UserArgs)
    if (-not (Test-Path (Join-Path $repo "client\project.godot"))) {
        throw "not a Marque checkout (missing client/project.godot)"
    }
    if (-not (Test-Path (Join-Path $repo "client\.godot"))) {
        Write-Host "review-evidence: warming client/.godot"
        & $Godot --headless --path (Join-Path $repo "client") --editor --quit | Out-Null
    }
    $all = @("--path", (Join-Path $repo "client"), "--quit-after", "3600", "--") + $UserArgs
    & $Godot @all
    if ($LASTEXITCODE -ne 0) {
        throw "godot exited $LASTEXITCODE"
    }
}

function Invoke-Stitch {
    param([string] $Prefix, [bool] $DoMp4, [bool] $DoGif)
    $first = "${Prefix}_1.png"
    if (-not (Test-Path -LiteralPath $first)) {
        throw "no $first to stitch"
    }
    if (-not $DoMp4 -and -not $DoGif) { $DoMp4 = $true }
    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffmpeg) { throw "ffmpeg is required to stitch frames (not installed)" }
    $vf = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    $input = "${Prefix}_%d.png"
    if ($DoMp4) {
        & ffmpeg -y -loglevel error -framerate 12 -start_number 1 -i $input -vf $vf -c:v libx264 -pix_fmt yuv420p "${Prefix}.mp4"
        Write-Host "review-evidence: wrote ${Prefix}.mp4"
    }
    if ($DoGif) {
        & ffmpeg -y -loglevel error -framerate 12 -start_number 1 -i $input -vf $vf "${Prefix}.gif"
        Write-Host "review-evidence: wrote ${Prefix}.gif"
    }
    Write-Host "REVIEW STITCH OK"
}

function Invoke-Attach {
    param([string[]] $Paths)
    if ($Paths.Count -eq 0) { throw "attach needs -Files" }
    if ($Paths.Count -gt 3) {
        Write-Host "review-evidence: taking the first 3 of $($Paths.Count) files (skill cap)"
        $Paths = $Paths[0..2]
    }
    $pr = Get-PrNumber $Pr
    $text = if ($Caption) { $Caption } else { "Reviewer-facing visual evidence" }
    $kindText = if ($Kind) { $Kind } else { "screenshot" }
    $attach = @()
    foreach ($f in $Paths) {
        if (-not (Test-Path -LiteralPath $f)) { throw "missing artifact: $f" }
        $attach += @("--attach", "$f#$text")
    }
    $body = @"
**Reviewer evidence** (human-visible; **not** a behavioural pass).

- Kind: ``$kindText``
- $text
- DEMO+GAMELOG (or Go / headless) still gate. PNG/video presence is never proof (ARM-289).
"@
    & gh pr comment $pr --body $body @attach
    if ($LASTEXITCODE -ne 0) { throw "gh pr comment failed" }
    Write-Host "REVIEW ATTACH OK"
}

New-Item -ItemType Directory -Force -Path $staging | Out-Null

switch ($Command) {
    "capture-screenshot" {
        if (-not $Out) { $Out = Join-Path $staging "baseline.png" }
        Assert-Absolute $Out "-Out"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
        if (-not $Kind) { $Kind = "screenshot" }
        Invoke-WindowedGodot @("--screenshot", $Out)
        if (-not (Test-Path -LiteralPath $Out)) { throw "capture wrote no file at $Out" }
        Write-Host "review-evidence: $Out"
        Write-Host "REVIEW CAPTURE OK"
        if ($Attach) { Invoke-Attach @($Out) }
    }
    "capture-frames" {
        if (-not $OutPrefix) { $OutPrefix = Join-Path $staging "frames" }
        Assert-Absolute $OutPrefix "-OutPrefix"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutPrefix) | Out-Null
        if (-not $Kind) { $Kind = "video" }
        Invoke-WindowedGodot @(
            "--record-frames", $OutPrefix,
            "--record-count", "$Count",
            "--record-interval-ms", "$IntervalMs"
        )
        if (-not (Test-Path -LiteralPath "${OutPrefix}_1.png")) {
            throw "capture wrote no ${OutPrefix}_1.png"
        }
        Write-Host "REVIEW CAPTURE OK"
        if ($Mp4 -or $Gif) { Invoke-Stitch -Prefix $OutPrefix -DoMp4:$Mp4 -DoGif:$Gif }
        if ($Attach) {
            $picked = @()
            if (Test-Path "${OutPrefix}.mp4") { $picked += "${OutPrefix}.mp4" }
            elseif (Test-Path "${OutPrefix}.gif") { $picked += "${OutPrefix}.gif" }
            else {
                $picked += "${OutPrefix}_1.png"
                if (Test-Path "${OutPrefix}_2.png") { $picked += "${OutPrefix}_2.png" }
                $last = "${OutPrefix}_${Count}.png"
                if ((Test-Path $last) -and ($last -ne "${OutPrefix}_1.png") -and ($last -ne "${OutPrefix}_2.png")) {
                    $picked += $last
                }
            }
            Invoke-Attach $picked
        }
    }
    "stitch" {
        if (-not $OutPrefix) { throw "stitch needs -OutPrefix" }
        Invoke-Stitch -Prefix $OutPrefix -DoMp4:$Mp4 -DoGif:$Gif
    }
    "attach" {
        Invoke-Attach $Files
    }
}
