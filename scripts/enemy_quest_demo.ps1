[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-enemy-quest")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "enemy_quest_demo.ps1 retired under ARM-290 (split into enemy_party + enemy_midchase + enemy_quest_turnin)."
Write-Host "Run scripts/enemy_party_demo.ps1, scripts/enemy_midchase_demo.ps1, scripts/enemy_quest_turnin_demo.ps1."
exit 1
