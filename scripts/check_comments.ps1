#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [ValidateSet('check', 'baseline')]
    [string]$Mode = 'check'
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    if ($PSScriptRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    else { $RepoRoot = (Get-Location).Path }
}

$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
$ratchetFile = Join-Path $PSScriptRoot 'comment-ratchet.json'
$include = @('*.gd', '*.go', '*.ps1')
$excludeDirs = @('[\\/]\.worktrees[\\/]', '[\\/]addons[\\/]', '[\\/]\.godot[\\/]', '[\\/]node_modules[\\/]')

function Get-RelPath([string]$Full) {
    $full = [System.IO.Path]::GetFullPath($Full)
    if (-not $full.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "path outside repo: $Full"
    }
    return $full.Substring($RepoRoot.Length + 1).Replace('\', '/')
}

function Get-ScopedFiles {
    Get-ChildItem -Recurse -File -Include $include `
        (Join-Path $RepoRoot 'client'), (Join-Path $RepoRoot 'server'), (Join-Path $RepoRoot 'scripts') |
        Where-Object {
            $full = $_.FullName
            -not ($excludeDirs | Where-Object { $full -match $_ }) -and
            $_.Name -ne 'check_comments.ps1'
        }
}

function Get-CommentLines([string]$Path) {
    @(Get-Content -LiteralPath $Path | Where-Object {
        $t = $_.TrimStart()
        if ($t -match '^#!') { return $false }
        return $t -match '^(#|//)'
    })
}

function Test-NarratingBody([string]$Body) {
    if ($Body -match '^(var |const |func |await |preload\(|push_error\(|push_warning\()') {
        return 'commented-out code'
    }
    if ($Body -match '^[=~_-]{6,}$') { return 'banner' }
    if ($Body -match '^Phase\s+\d') { return 'phase label' }
    if ($Body -match '^(Arrange|Act|Assert)\b') { return 'AAA label' }
    if ($Body -match '^(NOTE|HACK|XXX)\b[:\s]') { return 'stale marker' }
    return $null
}

$files = @(Get-ScopedFiles)
$perFile = @{}
$total = 0
$violations = [System.Collections.Generic.List[string]]::new()
$violationFiles = [System.Collections.Generic.HashSet[string]]::new()

foreach ($f in $files) {
    $rel = Get-RelPath $f.FullName
    $comments = Get-CommentLines $f.FullName
    $perFile[$rel] = $comments.Count
    $total += $comments.Count
    foreach ($c in $comments) {
        $body = ($c -replace '^(#+|//+)', '').Trim()
        $kind = Test-NarratingBody $body
        if ($kind) {
            $violations.Add(("{0}: {1}: {2}" -f $rel, $kind, $c.Trim())) | Out-Null
            [void]$violationFiles.Add($rel)
        }
    }
}

if ($Mode -eq 'baseline') {
    $payload = [ordered]@{
        total   = $total
        updated = (Get-Date).ToUniversalTime().ToString('o')
        files   = [ordered]@{}
    }
    foreach ($k in ($perFile.Keys | Sort-Object)) {
        $payload.files[$k] = $perFile[$k]
    }
    ($payload | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $ratchetFile -Encoding UTF8
    Write-Output ("BASELINE: total={0} files={1} -> {2}" -f $total, $perFile.Count, (Get-RelPath $ratchetFile))
    exit 0
}

if (-not (Test-Path -LiteralPath $ratchetFile)) {
    Write-Output "FAIL: no ratchet file. Run: scripts/check_comments.ps1 -Mode baseline"
    exit 1
}

$raw = Get-Content -LiteralPath $ratchetFile -Raw | ConvertFrom-Json
$cap = [int]$raw.total
if ($total -gt $cap) {
    $violations.Add(("repo: comment ratchet {0} exceeded with {1} (+{2})" -f $cap, $total, ($total - $cap))) | Out-Null
}

if ($violations.Count -gt 0) {
    $violations | ForEach-Object { Write-Output $_ }
    Write-Output ("FAIL: {0} violation(s) in {1} file(s); total comments={2} ratchet={3}" -f `
        $violations.Count, [math]::Max(1, $violationFiles.Count), $total, $cap)
    exit 1
}

Write-Output ("OK: {0} file(s); total comments={1} (ratchet {2})" -f $files.Count, $total, $cap)
exit 0
