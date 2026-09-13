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
    $csvHeader = Get-Content -LiteralPath (Join-Path $audit 'drive-candidates.csv') -TotalCount 1
    if ($csvHeader -ne '"id","action","path","bytes","lastWriteUtc","sha256","reason","risk"') { throw 'Empty CSV header test failed.' }
    $reportHeader = Get-Content -LiteralPath (Join-Path $audit 'drive-report.md') -TotalCount 1
    if ($reportHeader -ne "# Windows drive audit: $testDrive") { throw 'Markdown report header test failed.' }
  } finally {
    if (Test-Path -LiteralPath $audit) { Remove-Item -LiteralPath $audit -Recurse -Force }
  }
}
$tamperDir = Join-Path $env:TEMP ('wdc-tamper-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tamperDir | Out-Null
try {
  $protected = Get-Item -LiteralPath (Join-Path $root 'SKILL.md')
  $manifest = Join-Path $tamperDir 'manifest.json'
  $result = Join-Path $tamperDir 'result.json'
  [pscustomobject]@{schemaVersion=2;targetRoot=[IO.Path]::GetPathRoot($protected.FullName);candidates=@([pscustomobject]@{id='D0001';action='delete-low-risk';path=$protected.FullName;bytes=[long]$protected.Length;lastWriteUtc=$protected.LastWriteTimeUtc.ToString('o')})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding UTF8
  & $ps51 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\apply-approved.ps1') -Manifest $manifest -Ids D0001 -ResultPath $result | Out-Null
  $check = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
  if ($check.status -ne 'skipped' -or $check.message -notmatch 'classification') { throw 'Tampered-manifest test failed.' }
} finally {
  if (Test-Path -LiteralPath $tamperDir) { Remove-Item -LiteralPath $tamperDir -Recurse -Force }
}
$skill = Get-Content -LiteralPath (Join-Path $root 'SKILL.md') -Raw
if ($skill -notmatch '(?s)^---\s+name: windows-drive-cleanup\s+description:') { throw 'Invalid SKILL.md frontmatter.' }
if ($skill -match '\[TODO') { throw 'Unfinished placeholder found.' }
Write-Output 'Repository validation passed.'
