[CmdletBinding()]
param(
  [ValidatePattern('^[A-Za-z]:\\?$')][string]$DriveRoot = 'C:\',
  [string]$OutputDirectory = (Join-Path $PWD 'drive-audit'),
  [int]$TempMinimumAgeDays = 14,
  [int]$UserFileMinimumAgeDays = 30,
  [long]$MoveMinimumBytes = 268435456,
  [switch]$SkipUserContentScan,
  [switch]$AllCandidates,
  [ValidateRange(0,2147483647)][int]$MaxCandidates = 5000,
  [ValidateRange(10,86400)][int]$MaxScanSeconds = 300,
  [string[]]$AdditionalCloudRoot = @(),
  [switch]$WriteReports
)

$ErrorActionPreference = 'Stop'
$assessmentTempMinimumAgeDays = $TempMinimumAgeDays
if ($AllCandidates) {
  $TempMinimumAgeDays = 0
  $UserFileMinimumAgeDays = 0
  $MoveMinimumBytes = 0
  $MaxCandidates = 0
}
$driveFull = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($DriveRoot))
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $outputFull | Out-Null
$now = Get-Date
$items = [Collections.Generic.List[object]]::new()
$topItems = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
$retainedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$eligibleCount = 0L
$candidateSequence = 0L
$timeLimitReached = $false
$timer = [Diagnostics.Stopwatch]::StartNew()
$scanStopToken = '__WDC_SCAN_LIMIT__'

function Test-Readable([string]$Path) {
  try { $stream = [IO.File]::Open($Path,'Open','Read','None'); $stream.Dispose(); return $true } catch { return $false }
}

function Test-UnderRoot([string]$Path,[string]$Root) {
  $full=[IO.Path]::GetFullPath($Path)
  $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
  return $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)
}

function Add-Candidate([IO.FileInfo]$File,[string]$Action,[string]$Reason,[string]$SourceGroup) {
  if ($timer.Elapsed.TotalSeconds -ge $MaxScanSeconds) { $script:timeLimitReached=$true; return }
  $blocked = [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::Offline -bor [IO.FileAttributes]::Encrypted -bor [IO.FileAttributes]::SparseFile
  if (($File.Attributes -band $blocked) -ne 0 -or -not (Test-Readable $File.FullName)) { return }
  if ($retainedPaths.Contains($File.FullName)) { return }
  $script:eligibleCount++
  $script:candidateSequence++
  $risk = if($Action -eq 'delete-low-risk'){'Low risk; temporary recovery or diagnostic data may be lost.'}elseif($Action -eq 'delete-review'){'Review required; recent temporary data may still be needed by its owning application.'}else{'Review required; moving may break shortcuts or application references.'}
  $candidate = [pscustomobject]@{
    action=$Action; sourceGroup=$SourceGroup; path=$File.FullName; bytes=[long]$File.Length
    lastWriteUtc=$File.LastWriteTimeUtc.ToString('o'); sha256=$null; reason=$Reason
    risk=$risk
  }
  if ($MaxCandidates -eq 0) {
    $items.Add($candidate)
    [void]$retainedPaths.Add($File.FullName)
    return
  }
  $key = $File.Length.ToString('D20') + ':' + $candidateSequence.ToString('D20')
  $topItems.Add($key,$candidate)
  [void]$retainedPaths.Add($File.FullName)
  if ($topItems.Count -gt $MaxCandidates) {
    $keys = $topItems.Keys.GetEnumerator()
    [void]$keys.MoveNext()
    $smallestKey = $keys.Current
    $removedPath = $topItems[$smallestKey].path
    [void]$topItems.Remove($smallestKey)
    [void]$retainedPaths.Remove($removedPath)
  }
}

$cloudRoots = @(
  $env:OneDrive,$env:OneDriveConsumer,$env:OneDriveCommercial,
  (Join-Path $env:USERPROFILE 'Dropbox'),(Join-Path $env:USERPROFILE 'Google Drive'),
  (Join-Path $env:USERPROFILE 'GoogleDrive'),(Join-Path $env:USERPROFILE 'iCloudDrive'),
  (Join-Path $env:USERPROFILE 'Box'),(Join-Path $env:USERPROFILE 'Nutstore'),
  $AdditionalCloudRoot
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique

$tempRoots = @(
  (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp'),
  'C:\Windows\Temp',
  (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'),
  (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue'),
  (Join-Path $env:LOCALAPPDATA 'CrashDumps')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) -and [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($_)) -eq $driveFull } | Select-Object -Unique

$tempCutoff = $now.AddDays(-$TempMinimumAgeDays)
$assessmentTempCutoff = $now.AddDays(-$assessmentTempMinimumAgeDays)
try {
foreach ($root in $tempRoots) {
  $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
  Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($timer.Elapsed.TotalSeconds -ge $MaxScanSeconds) { $script:timeLimitReached=$true; throw $scanStopToken }
    $candidateFull = [IO.Path]::GetFullPath($_.FullName)
    if ($candidateFull.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase) -and $_.LastWriteTime -lt $tempCutoff) {
      $deleteAction = if ($_.LastWriteTime -lt $assessmentTempCutoff) { 'delete-low-risk' } else { 'delete-review' }
      $deleteReason = if ($deleteAction -eq 'delete-low-risk') { 'Old disposable file under allowed root: ' + $root } else { 'Recent temporary file; confirm the owning application is closed: ' + $root }
      Add-Candidate $_ $deleteAction $deleteReason $root
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
$userCutoff = $now.AddDays(-$UserFileMinimumAgeDays)
if (-not $SkipUserContentScan -and -not $timeLimitReached -and $driveFull -eq 'C:\') { foreach ($entry in $knownFolders.GetEnumerator()) {
  $name = $entry.Key
  $root = $entry.Value
  if (-not (Test-Path -LiteralPath $root -PathType Container) -or [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root)) -ne $driveFull) { continue }
  Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($timer.Elapsed.TotalSeconds -ge $MaxScanSeconds) { $script:timeLimitReached=$true; throw $scanStopToken }
    $badAttributes = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Offline
    $inCloud=$false
    foreach($cloudRoot in $cloudRoots) { if (Test-UnderRoot $_.FullName $cloudRoot) { $inCloud=$true; break } }
    if (-not $inCloud -and $_.Length -ge $MoveMinimumBytes -and $_.LastWriteTime -lt $userCutoff -and $allowedExt -contains $_.Extension.ToLowerInvariant() -and ($_.Attributes -band $badAttributes) -eq 0 -and $_.FullName -notmatch '[\\/]\.git[\\/]') {
      Add-Candidate $_ 'move-review' ('User file in ' + $name) $root
    }
  }
} }

if (-not $SkipUserContentScan -and -not $timeLimitReached -and $driveFull -ne 'C:\') {
  $excludedPattern = '[\\/](Windows|Program Files|Program Files \(x86\)|ProgramData|Recovery|System Volume Information|\$Recycle\.Bin|AppData|node_modules|\.git)([\\/]|$)'
  Get-ChildItem -LiteralPath $driveFull -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($timer.Elapsed.TotalSeconds -ge $MaxScanSeconds) { $script:timeLimitReached=$true; throw $scanStopToken }
    $badAttributes = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Offline
    $inCloud=$false
    foreach($cloudRoot in $cloudRoots) { if (Test-UnderRoot $_.FullName $cloudRoot) { $inCloud=$true; break } }
    $inTemp=$false
    foreach($tempRoot in $tempRoots) { if (Test-UnderRoot $_.FullName $tempRoot) { $inTemp=$true; break } }
    if (-not $inCloud -and -not $inTemp -and $_.Length -ge $MoveMinimumBytes -and $_.LastWriteTime -lt $userCutoff -and $allowedExt -contains $_.Extension.ToLowerInvariant() -and ($_.Attributes -band $badAttributes) -eq 0 -and $_.FullName -notmatch $excludedPattern) {
      $relative = $_.FullName.Substring($driveFull.Length).TrimStart('\')
      $firstPart = @($relative -split '\\')[0]
      $sourceGroup = if ($firstPart) { Join-Path $driveFull $firstPart } else { $driveFull }
      Add-Candidate $_ 'move-review' 'User-content file on selected non-system drive' $sourceGroup
    }
  }
}
} catch {
  if ($_.Exception.Message -ne $scanStopToken) { throw }
}

$retained = if ($MaxCandidates -eq 0) { $items } else { $topItems.Values }
$sorted = @($retained | Sort-Object @{Expression='bytes';Descending=$true},action)
$deleteCounter = 0
$moveCounter = 0
foreach ($item in $sorted) {
  if ($item.action -like 'delete-*') { $deleteCounter++; $id = 'D{0:D4}' -f $deleteCounter }
  else { $moveCounter++; $id = 'M{0:D4}' -f $moveCounter }
  $item | Add-Member -NotePropertyName id -NotePropertyValue $id
}
$groupMap = @{}
$groupNumber = 0
foreach ($sourceGroup in @($sorted.sourceGroup | Sort-Object -Unique)) {
  $groupNumber++
  $groupMap[[string]$sourceGroup] = $groupNumber
}
foreach ($item in $sorted) { $item | Add-Member -NotePropertyName groupId -NotePropertyValue $groupMap[[string]$item.sourceGroup] }
$outputTruncated = $MaxCandidates -gt 0 -and $eligibleCount -gt $MaxCandidates
$limitReached = $timeLimitReached -or $outputTruncated
$jsonPath = Join-Path $outputFull 'drive-candidates.json'
$csvPath = $null
$mdPath = $null
$driveInfo = [IO.DriveInfo]::new($driveFull)
[pscustomobject]@{schemaVersion=3;hashPolicy='deferred-until-approved-execution';targetRoot=$driveFull;scannedAtUtc=(Get-Date).ToUniversalTime().ToString('o');computer=$env:COMPUTERNAME;user=$env:USERNAME;freeBytesBefore=$driveInfo.AvailableFreeSpace;allCandidates=[bool]$AllCandidates;tempMinimumAgeDays=$TempMinimumAgeDays;userFileMinimumAgeDays=$UserFileMinimumAgeDays;moveMinimumBytes=$MoveMinimumBytes;limitReached=$limitReached;timeLimitReached=$timeLimitReached;outputTruncated=$outputTruncated;eligibleCount=$eligibleCount;returnedCount=$sorted.Count;maxCandidates=$MaxCandidates;maxScanSeconds=$MaxScanSeconds;cloudRoots=@($cloudRoots);candidates=$sorted} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$csvColumns=@('groupId','sourceGroup','id','action','path','bytes','lastWriteUtc','sha256','reason','risk')
$sum = ($sorted | Measure-Object bytes -Sum).Sum
if ($null -eq $sum) { $sum = 0 }
if ($WriteReports) {
  $csvPath = Join-Path $outputFull 'drive-candidates.csv'
  $mdPath = Join-Path $outputFull 'drive-report.md'
  if ($sorted.Count) { $sorted | Select-Object $csvColumns | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 }
  else { ('"'+($csvColumns -join '","')+'"') | Set-Content -LiteralPath $csvPath -Encoding UTF8 }
  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in @("# Windows drive audit: $driveFull",'','Read-only scan. No files were moved or deleted.','','| Group | ID | Action | MiB | Last modified UTC | Path | Reason |','|---:|---|---|---:|---|---|---|')) { [void]$lines.Add($line) }
  foreach($item in $sorted){
    $safePath=[Net.WebUtility]::HtmlEncode($item.path); $safeReason=$item.reason.Replace('|','\|')
    [void]$lines.Add(('| {0} | {1} | {2} | {3:N1} | {4} | <code>{5}</code> | {6} |' -f $item.groupId,$item.id,$item.action,($item.bytes/1MB),$item.lastWriteUtc,$safePath,$safeReason))
  }
  [void]$lines.Add(''); [void]$lines.Add(('Total candidates: {0}; potential bytes: {1}' -f $sorted.Count,$sum))
  if ($outputTruncated) { [void]$lines.Add(('Output truncated after sorting by size: showing the largest {0} of {1} eligible candidates. Increase MaxCandidates to return more.' -f $sorted.Count,$eligibleCount)) }
  if ($timeLimitReached) { [void]$lines.Add('Time limit reached; the filesystem scan is incomplete. Increase MaxScanSeconds for a deeper scan.') }
  $lines | Set-Content -LiteralPath $mdPath -Encoding UTF8
}
[pscustomobject]@{Json=$jsonPath;Csv=$csvPath;Markdown=$mdPath;AllCandidates=[bool]$AllCandidates;Count=$sorted.Count;EligibleCount=$eligibleCount;PotentialBytes=$sum;LimitReached=$limitReached;TimeLimitReached=$timeLimitReached;OutputTruncated=$outputTruncated;ScanSeconds=[Math]::Round($timer.Elapsed.TotalSeconds,2)}
