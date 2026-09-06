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

$budgetFile = Join-Path $PSScriptRoot 'comment-budgets.json'
$include = @('*.gd', '*.go', '*.ps1')
$excludeDirs = @('[\\/]\.worktrees[\\/]', '[\\/]addons[\\/]', '[\\/]\.godot[\\/]', '[\\/]node_modules[\\/]')

function Get-ScopedFiles {
    Get-ChildItem -Recurse -File -Include $include (Join-Path $RepoRoot 'client'), (Join-Path $RepoRoot 'server'), (Join-Path $RepoRoot 'scripts') |
        Where-Object { $full = $_.FullName; -not ($excludeDirs | Where-Object { $full -match $_ }) }
}

function Get-CommentStats {
    param($Path)
    $lines = Get-Content -LiteralPath $Path.FullName
    $comments = @($lines | Where-Object { $_.TrimStart() -match '^(#|//)' })
    @{ Total = $lines.Count; Comments = $comments; Count = $comments.Count }
}

if ($Mode -eq 'baseline') {
    $budgets = @{}
    foreach ($f in Get-ScopedFiles) {
        $count = (Get-CommentStats $f).Count
        $rel = [System.IO.Path]::GetFullPath($f.FullName).Substring(
            [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\').Length + 1).Replace('\', '/')
        $budgets[$rel] = [int][math]::Ceiling($count * 1.1)
    }
    $budgets | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $budgetFile -Encoding UTF8
    Write-Output ("BASELINE: {0} file(s) written to {1}" -f $budgets.Count, $budgetFile)
    exit 0
}

if (-not (Test-Path -LiteralPath $budgetFile)) {
    Write-Output "FAIL: no budget file. Run: scripts/check_comments.ps1 -Mode baseline"
    exit 1
}
$budgets = @{}
$raw = Get-Content -LiteralPath $budgetFile -Raw | ConvertFrom-Json
foreach ($prop in $raw.PSObject.Properties) {
    $budgets[$prop.Name] = [int]$prop.Value
}

$violations = [System.Collections.Generic.List[string]]::new()
$violationFiles = [System.Collections.Generic.HashSet[string]]::new()

foreach ($f in Get-ScopedFiles) {
    $stats = Get-CommentStats $f
    if ($budgets.ContainsKey($f.FullName) -and $stats.Count -gt $budgets[$f.FullName]) {
        $over = $stats.Count - $budgets[$f.FullName]
        $violations.Add(("{0}: comment budget {1} exceeded with {2} (+{3} since baseline)" -f `
            $f.FullName, $budgets[$f.FullName], $stats.Count, $over)) | Out-Null
        [void]$violationFiles.Add($f.FullName)
    }
    foreach ($c in $stats.Comments) {
        $body = ($c -replace '^(#+|//+)', '').Trim()
        if ($body -match '^(var |const |func |await |preload\(|push_error\(|push_warning\()') {
            $violations.Add(("{0}: commented-out code: {1}" -f $f.FullName, $c.Trim())) | Out-Null
            [void]$violationFiles.Add($f.FullName)
        }
        if ($body -match '^[=~_-]{6,}$') {
            $violations.Add(("{0}: banner comment: {1}" -f $f.FullName, $c.Trim())) | Out-Null
            [void]$violationFiles.Add($f.FullName)
        }
        if ($body -match '^Phase\s+\d') {
            $violations.Add(("{0}: phase label: {1}" -f $f.FullName, $c.Trim())) | Out-Null
            [void]$violationFiles.Add($f.FullName)
        }
        if ($body -match '^(Arrange|Act|Assert)\b') {
            $violations.Add(("{0}: AAA label: {1}" -f $f.FullName, $c.Trim())) | Out-Null
            [void]$violationFiles.Add($f.FullName)
        }
    }
}

if ($violations.Count -gt 0) {
    $violations | ForEach-Object { Write-Output $_ }
    Write-Output ("FAIL: {0} violation(s) in {1} file(s)" -f $violations.Count, $violationFiles.Count)
    exit 1
}

Write-Output ("OK: {0} file(s) checked against {1} budget(s)" -f (Get-ScopedFiles).Count, $budgets.Count)
exit 0
