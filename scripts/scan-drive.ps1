[CmdletBinding()]
param(
  [ValidatePattern('^[A-Za-z]:\\?$')][string]$DriveRoot = 'C:\',
  [string]$OutputDirectory = (Join-Path $PWD 'drive-audit'),
  [int]$TempMinimumAgeDays = 14,
  [int]$UserFileMinimumAgeDays = 30,
  [long]$MoveMinimumBytes = 268435456,
  [switch]$SkipUserContentScan
)

$ErrorActionPreference = 'Stop'
$driveFull = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($DriveRoot))
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $outputFull | Out-Null
$now = Get-Date
$items = [Collections.Generic.List[object]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$deleteCounter = 0
$moveCounter = 0

function Test-Readable([string]$Path) {
  try { $stream = [IO.File]::Open($Path,'Open','Read','None'); $stream.Dispose(); return $true } catch { return $false }
}

function Test-UnderRoot([string]$Path,[string]$Root) {
  $full=[IO.Path]::GetFullPath($Path)
  $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
  return $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)
}

function Add-Candidate([IO.FileInfo]$File,[string]$Action,[string]$Reason) {
  $blocked = [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::Offline -bor [IO.FileAttributes]::Encrypted -bor [IO.FileAttributes]::SparseFile
  if (($File.Attributes -band $blocked) -ne 0 -or -not (Test-Readable $File.FullName)) { return }
  if (-not $seen.Add($File.FullName)) { return }
  if ($Action -eq 'delete-low-risk') { $script:deleteCounter++; $id = 'D{0:D4}' -f $script:deleteCounter }
  else { $script:moveCounter++; $id = 'M{0:D4}' -f $script:moveCounter }
  $risk = if($Action -eq 'delete-low-risk'){'Low risk; temporary recovery or diagnostic data may be lost.'}else{'Review required; moving may break shortcuts or application references.'}
  $items.Add([pscustomobject]@{
    id=$id; action=$Action; path=$File.FullName; bytes=[long]$File.Length
    lastWriteUtc=$File.LastWriteTimeUtc.ToString('o'); sha256=$null; reason=$Reason
    risk=$risk
  })
}

$tempRoots = @(
  [Environment]::GetEnvironmentVariable('TEMP','User'),
  'C:\Windows\Temp',
  (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'),
  (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue'),
  (Join-Path $env:LOCALAPPDATA 'CrashDumps')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) -and [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($_)) -eq $driveFull } | Select-Object -Unique

$tempCutoff = $now.AddDays(-$TempMinimumAgeDays)
foreach ($root in $tempRoots) {
  $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
  Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $candidateFull = [IO.Path]::GetFullPath($_.FullName)
    if ($candidateFull.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase) -and $_.LastWriteTime -lt $tempCutoff) {
      Add-Candidate $_ 'delete-low-risk' ('Old disposable file under allowed root: ' + $root)
    }
  }
}

$knownFolders = [ordered]@{
  Downloads = (Join-Path $env:USERPROFILE 'Downloads')
  Documents = [Environment]::GetFolderPath('MyDocuments')
  Desktop = [Environment]::GetFolderPath('Desktop')
  Videos = [Environment]::GetFolderPath('MyVideos')
  Music = [Environment]::GetFolderPath('MyMusic')
  Pictures = [Environment]::GetFolderPath('MyPictures')
}
$allowedExt = @('.zip','.7z','.rar','.tar','.gz','.iso','.img','.mp4','.mkv','.mov','.avi','.webm','.mp3','.wav','.flac','.jpg','.jpeg','.png','.gif','.webp','.tif','.tiff','.pdf','.doc','.docx','.ppt','.pptx','.xls','.xlsx','.exe','.msi')
$cloudRoots = @($env:OneDrive,$env:OneDriveConsumer,$env:OneDriveCommercial) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique
$userCutoff = $now.AddDays(-$UserFileMinimumAgeDays)
if (-not $SkipUserContentScan) { foreach ($entry in $knownFolders.GetEnumerator()) {
  $name = $entry.Key
  $root = $entry.Value
  if (-not (Test-Path -LiteralPath $root -PathType Container) -or [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root)) -ne $driveFull) { continue }
  Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $badAttributes = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Offline
    $inCloud=$false
    foreach($cloudRoot in $cloudRoots) { if (Test-UnderRoot $_.FullName $cloudRoot) { $inCloud=$true; break } }
    if (-not $inCloud -and $_.Length -ge $MoveMinimumBytes -and $_.LastWriteTime -lt $userCutoff -and $allowedExt -contains $_.Extension.ToLowerInvariant() -and ($_.Attributes -band $badAttributes) -eq 0 -and $_.FullName -notmatch '[\\/]\.git[\\/]') {
      Add-Candidate $_ 'move-review' ('Large user file in ' + $name)
    }
  }
} }

if (-not $SkipUserContentScan -and $driveFull -ne 'C:\') {
  $excludedPattern = '[\\/](Windows|Program Files|Program Files \(x86\)|ProgramData|Recovery|System Volume Information|\$Recycle\.Bin|AppData|node_modules|\.git)([\\/]|$)'
  Get-ChildItem -LiteralPath $driveFull -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $badAttributes = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Offline
    $inCloud=$false
    foreach($cloudRoot in $cloudRoots) { if (Test-UnderRoot $_.FullName $cloudRoot) { $inCloud=$true; break } }
    if (-not $inCloud -and $_.Length -ge $MoveMinimumBytes -and $_.LastWriteTime -lt $userCutoff -and $allowedExt -contains $_.Extension.ToLowerInvariant() -and ($_.Attributes -band $badAttributes) -eq 0 -and $_.FullName -notmatch $excludedPattern) {
      Add-Candidate $_ 'move-review' 'Large user-content file on selected non-system drive'
    }
  }
}

$sorted = @($items | Sort-Object action,@{Expression='bytes';Descending=$true})
$jsonPath = Join-Path $outputFull 'drive-candidates.json'
$csvPath = Join-Path $outputFull 'drive-candidates.csv'
$mdPath = Join-Path $outputFull 'drive-report.md'
$driveInfo = [IO.DriveInfo]::new($driveFull)
[pscustomobject]@{schemaVersion=2;hashPolicy='deferred-until-approved-execution';targetRoot=$driveFull;scannedAtUtc=(Get-Date).ToUniversalTime().ToString('o');computer=$env:COMPUTERNAME;user=$env:USERNAME;freeBytesBefore=$driveInfo.AvailableFreeSpace;candidates=$sorted} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$sorted | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
$lines = @('# Windows drive audit: ' + $driveFull,'','Read-only scan. No files were moved or deleted.','','| ID | Action | MiB | Last modified UTC | Path | Reason |','|---|---|---:|---|---|---|')
foreach($item in $sorted){
  $safePath=$item.path.Replace('|','\|'); $safeReason=$item.reason.Replace('|','\|')
  $lines += ('| {0} | {1} | {2:N1} | {3} | `{4}` | {5} |' -f $item.id,$item.action,($item.bytes/1MB),$item.lastWriteUtc,$safePath,$safeReason)
}
$sum = ($sorted | Measure-Object bytes -Sum).Sum
if ($null -eq $sum) { $sum = 0 }
$lines += ''; $lines += ('Total candidates: {0}; potential bytes: {1}' -f $sorted.Count,$sum)
$lines | Set-Content -LiteralPath $mdPath -Encoding UTF8
[pscustomobject]@{Json=$jsonPath;Csv=$csvPath;Markdown=$mdPath;Count=$sorted.Count;PotentialBytes=$sum}
