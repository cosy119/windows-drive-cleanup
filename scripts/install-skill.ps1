[CmdletBinding()]
param([string]$DestinationRoot)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
  $DestinationRoot = if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'skills' } else { Join-Path $env:USERPROFILE '.codex\skills' }
}
$destination = Join-Path ([IO.Path]::GetFullPath($DestinationRoot)) 'windows-drive-cleanup'
if (Test-Path -LiteralPath $destination) {
  throw "Skill already exists: $destination. Remove or rename it manually before reinstalling."
}
New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
Copy-Item -LiteralPath $skillRoot -Destination $destination -Recurse
Write-Output "Installed skill to: $destination"
