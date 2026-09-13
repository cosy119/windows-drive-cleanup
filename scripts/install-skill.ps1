[CmdletBinding()]
param(
  [string]$DestinationRoot,
  [ValidateSet('Codex','WorkBuddy')][string]$Platform = 'Codex'
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
  if ($Platform -eq 'WorkBuddy') { $DestinationRoot=Join-Path $env:USERPROFILE '.workbuddy\skills' }
  else { $DestinationRoot = if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'skills' } else { Join-Path $env:USERPROFILE '.codex\skills' } }
}
$destination = Join-Path ([IO.Path]::GetFullPath($DestinationRoot)) 'windows-drive-cleanup'
$sourceFull = [IO.Path]::GetFullPath($skillRoot).TrimEnd('\') + '\'
$destinationFull = [IO.Path]::GetFullPath($destination).TrimEnd('\') + '\'
if ($destinationFull.StartsWith($sourceFull,[StringComparison]::OrdinalIgnoreCase)) {
  throw 'Destination must not be inside the source repository.'
}
if (Test-Path -LiteralPath $destination) {
  throw "Skill already exists: $destination. Remove or rename it manually before reinstalling."
}
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Destination $destination
foreach($name in @('agents','references','scripts')) {
  Copy-Item -LiteralPath (Join-Path $skillRoot $name) -Destination (Join-Path $destination $name) -Recurse
}
Write-Output "Installed skill to: $destination"
