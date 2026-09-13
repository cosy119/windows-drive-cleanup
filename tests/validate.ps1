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
$scanText = Get-Content -LiteralPath (Join-Path $root 'scripts\scan-drive.ps1') -Raw
if ($scanText -match 'New-Item\s+[^\r\n]*-LiteralPath') {
  throw 'New-Item -LiteralPath is incompatible with Windows PowerShell 5.1.'
}
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath $ps51) {
  $audit = Join-Path $env:TEMP ('wdc-validate-' + [Guid]::NewGuid().ToString('N'))
  $testDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root))
  try {
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\scan-drive.ps1') -DriveRoot $testDrive -OutputDirectory $audit -SkipUserContentScan | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell 5.1 scan smoke test failed.' }
  } finally {
    if (Test-Path -LiteralPath $audit) { Remove-Item -LiteralPath $audit -Recurse -Force }
  }
}
$skill = Get-Content -LiteralPath (Join-Path $root 'SKILL.md') -Raw
if ($skill -notmatch '(?s)^---\s+name: windows-drive-cleanup\s+description:') { throw 'Invalid SKILL.md frontmatter.' }
if ($skill -match '\[TODO') { throw 'Unfinished placeholder found.' }
Write-Output 'Repository validation passed.'
