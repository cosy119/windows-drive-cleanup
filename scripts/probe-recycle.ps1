[CmdletBinding()]
param(
  [string]$ScratchRoot
)

# Probes the destructive primitive this skill depends on, using a file it creates itself.
# Run it before a bulk run whenever host behaviour is unknown (sandboxed sessions,
# non-interactive shells, restricted endpoint agents). Nothing outside the scratch file
# is touched, and the probe file is created inside a recognised temp root so the same
# classification rules as apply-approved.ps1 are exercised.

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScratchRoot)) {
  $ScratchRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp'
}
$ScratchRoot = [IO.Path]::GetFullPath($ScratchRoot)
if (-not (Test-Path -LiteralPath $ScratchRoot)) { New-Item -ItemType Directory -Force -Path $ScratchRoot | Out-Null }

$stamp = [Guid]::NewGuid().ToString('N').Substring(0,8)
$scratch = Join-Path $ScratchRoot ('wdc-recycle-probe-' + $stamp + '.tmp')
$report = Join-Path $ScratchRoot ('wdc-recycle-probe-' + $stamp + '.json')
$result = [ordered]@{
  scratchRoot        = $ScratchRoot
  probePath          = $scratch
  recycleApi         = 'unknown'
  exceptionRaised    = $false
  exceptionMessage   = $null
  sourceStillPresent = $null
  verdict            = 'inconclusive'
  note               = $null
}

try {
  try {
    Add-Type -AssemblyName Microsoft.VisualBasic
  } catch {
    throw ('Microsoft.VisualBasic is unavailable, so Send-to-Recycle-Bin cannot be used at all. ' + $_.Exception.Message)
  }

  [IO.File]::WriteAllBytes($scratch, [byte[]](1..128))

  try {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($scratch, 'OnlyErrorDialogs', 'SendToRecycleBin')
  } catch {
    $result.exceptionRaised = $true
    $result.exceptionMessage = $_.Exception.Message
  }

  $result.sourceStillPresent = Test-Path -LiteralPath $scratch

  if (-not $result.sourceStillPresent) {
    $result.recycleApi = 'operational'
    if ($result.exceptionRaised) {
      $result.verdict = 'spurious-error'
      $result.note = 'The Recycle Bin call raised an error but the probe path is gone, so recycling works. Judge every outcome by observing the source path and never by the exception.'
    } else {
      $result.verdict = 'clean'
      $result.note = 'The Recycle Bin call succeeded without reporting an error.'
    }
  } else {
    $result.recycleApi = 'blocked'
    $result.verdict = 'not-removable'
    $result.note = 'The probe file survived the call. Send-to-Recycle-Bin is unavailable in this host. Ask for a separate explicit decision before removing files by any other means.'
  }
} catch {
  $result.verdict = 'probe-failed'
  $result.note = $_.Exception.Message
} finally {
  if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue }
}

[pscustomobject]$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $report -Encoding UTF8
[pscustomobject]$result | Format-List | Out-String -Width 200 | Write-Output
Write-Output ('Probe report: ' + $report)
