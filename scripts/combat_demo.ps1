# ARM-284: fail-closed stub. The two-client PvP combat demo is retired (ARM-203).
# Use scripts/dummy_attack_demo.ps1 or scripts/tab_combat_demo.ps1 instead.
[CmdletBinding()]
param(
    [string] $Godot = $(if ($env:GODOT) { $env:GODOT } else { "godot" }),
    [string] $OutDir = (Join-Path ([System.IO.Path]::GetTempPath()) "marque-combat")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "combat_demo.ps1 retired under ARM-284 (PvP attack is refused)."
Write-Host "Run scripts/dummy_attack_demo.ps1 or scripts/tab_combat_demo.ps1 for Combat-class vs NPC proof."
exit 1
