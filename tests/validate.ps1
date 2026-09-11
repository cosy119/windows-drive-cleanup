[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$required = @('SKILL.md','agents\openai.yaml','references\classification.md','scripts\scan-drive.ps1','scripts\apply-approved.ps1','scripts\install-skill.ps1')
foreach ($relative in $required) {
  if (-not (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf)) { throw "Missing required file: $relative" }
}
foreach ($script in Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1') {
  $tokens=$null; $errors=$null
  [void][Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tokens,[ref]$errors)
  if ($errors.Count) { throw "PowerShell syntax error in $($script.Name): $($errors[0].Message)" }
}
$skill = Get-Content -LiteralPath (Join-Path $root 'SKILL.md') -Raw
if ($skill -notmatch '(?s)^---\s+name: windows-drive-cleanup\s+description:') { throw 'Invalid SKILL.md frontmatter.' }
if ($skill -match '\[TODO') { throw 'Unfinished placeholder found.' }
Write-Output 'Repository validation passed.'
