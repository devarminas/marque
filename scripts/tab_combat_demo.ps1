[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-tab-combat")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "tab_combat_demo.ps1 retired under ARM-290 (split into focused units)."
Write-Host "Run scripts/wasd_demo.ps1, scripts/dummy_cast_demo.ps1, scripts/dummy_attack_demo.ps1, scripts/heal_wounded_demo.ps1."
exit 1
