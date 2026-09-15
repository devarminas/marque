[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-gather-craft")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "gather_craft_demo.ps1 retired under ARM-287 (empty join kit / stale axe+weapon asserts; not on wish+pose+/give verify path)."
Write-Host "Run scripts/gather_error_demo.ps1 for live gather proof. Contested craft race needs a later migrate."
exit 1
