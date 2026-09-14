[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-craft-cast")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "craft_cast_demo.ps1 retired under ARM-290 (split into mine_smelt_craft + cast_bar)."
Write-Host "Run scripts/mine_smelt_craft_demo.ps1 and scripts/cast_bar_demo.ps1."
exit 1
