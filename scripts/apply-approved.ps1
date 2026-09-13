[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Manifest,
  [Parameter(Mandatory)][string[]]$Ids,
  [string]$MoveRoot,
  [switch]$Execute,
  [string]$ConfirmToken,
  [switch]$PermanentDelete,
  [string]$ResultPath
)

$ErrorActionPreference='Stop'
if ($PermanentDelete) { throw 'Permanent deletion is unsupported. Use the Recycle Bin and review it separately.' }

function Test-UnderRoot([string]$Path,[string]$Root) {
  $full=[IO.Path]::GetFullPath($Path)
  $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
  return $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)
}

function Test-ApprovedClassification([IO.FileInfo]$File,[string]$Action,[string]$TargetRoot) {
  $tempRoots=@(
    (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp'),'C:\Windows\Temp',
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue'),
    (Join-Path $env:LOCALAPPDATA 'CrashDumps')
  ) | Where-Object { $_ -and [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($_)) -eq $TargetRoot } | Select-Object -Unique
  if ($Action -eq 'delete-low-risk') {
    foreach($root in $tempRoots) { if (Test-UnderRoot $File.FullName $root) { return $true } }
    return $false
  }
  if ($Action -ne 'move-review') { return $false }
  $allowedExt=@('.zip','.7z','.rar','.tar','.gz','.iso','.img','.mp4','.mkv','.mov','.avi','.webm','.mp3','.wav','.flac','.jpg','.jpeg','.png','.gif','.webp','.tif','.tiff','.pdf','.doc','.docx','.ppt','.pptx','.xls','.xlsx','.exe','.msi')
  if ($allowedExt -notcontains $File.Extension.ToLowerInvariant()) { return $false }
  $cloudRoots=@(
    $env:OneDrive,$env:OneDriveConsumer,$env:OneDriveCommercial,
    (Join-Path $env:USERPROFILE 'Dropbox'),(Join-Path $env:USERPROFILE 'Google Drive'),
    (Join-Path $env:USERPROFILE 'GoogleDrive'),(Join-Path $env:USERPROFILE 'iCloudDrive'),
    (Join-Path $env:USERPROFILE 'Box'),(Join-Path $env:USERPROFILE 'Nutstore'),
    (Join-Path $env:USERPROFILE '坚果云'),$data.cloudRoots
  ) | Where-Object { $_ } | Select-Object -Unique
  foreach($root in $cloudRoots) { if (Test-UnderRoot $File.FullName $root) { return $false } }
  if ($TargetRoot -eq 'C:\') {
    $known=@((Join-Path $env:USERPROFILE 'Downloads'),[Environment]::GetFolderPath('MyDocuments'),[Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('MyVideos'),[Environment]::GetFolderPath('MyMusic'),[Environment]::GetFolderPath('MyPictures')) | Where-Object { $_ } | Select-Object -Unique
    foreach($root in $known) { if (Test-UnderRoot $File.FullName $root) { return $true } }
    return $false
  }
  $excluded='[\/](Windows|Program Files|Program Files \(x86\)|ProgramData|Recovery|System Volume Information|\$Recycle\.Bin|AppData|node_modules|\.git)([\/]|$)'
  return $File.FullName -notmatch $excluded
}

$data=Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$targetRoot=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath([string]$data.targetRoot))
$normalizedIds=@($Ids | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($normalizedIds.Count -ne @($normalizedIds | Select-Object -Unique).Count) { throw 'Duplicate IDs were supplied.' }
$approved=@($data.candidates | Where-Object { $normalizedIds -contains $_.id })
if ($approved.Count -ne $normalizedIds.Count) { throw 'One or more IDs are absent or duplicated in the manifest.' }
if ($Execute -and $ConfirmToken -cne 'CONFIRM') { throw 'Execution requires -ConfirmToken CONFIRM.' }
if ($approved.action -contains 'move-review' -and [string]::IsNullOrWhiteSpace($MoveRoot)) { throw 'MoveRoot is required for move-review items.' }
if ($MoveRoot) {
  $moveFull=[IO.Path]::GetFullPath($MoveRoot)
  if ([IO.Path]::GetPathRoot($moveFull) -eq $targetRoot) { throw 'MoveRoot must be on a different volume from the scanned drive.' }
}
Add-Type -AssemblyName Microsoft.VisualBasic
$stamp=(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$results=[Collections.Generic.List[object]]::new()
foreach($item in $approved){
  $status='preview'; $destination=$null; $message='No change made.'; $copyStarted=$false
  try {
    $file=Get-Item -LiteralPath $item.path -Force
    if ([IO.Path]::GetPathRoot($file.FullName) -ne $targetRoot) { throw 'File is outside the manifest target drive.' }
    $blocked=[IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::Offline -bor [IO.FileAttributes]::Encrypted -bor [IO.FileAttributes]::SparseFile
    if ($file.PSIsContainer -or ($file.Attributes -band $blocked) -ne 0) { throw 'Not an eligible regular file.' }
    if ([long]$file.Length -ne [long]$item.bytes -or $file.LastWriteTimeUtc.ToString('o') -ne $item.lastWriteUtc) { throw 'File changed after scan.' }
    if (-not (Test-ApprovedClassification $file ([string]$item.action) $targetRoot)) { throw 'Manifest classification is not valid for this path.' }
    if (($item.action -eq 'delete-low-risk' -and $item.id -notmatch '^D\d+$') -or ($item.action -eq 'move-review' -and $item.id -notmatch '^M\d+$')) { throw 'Manifest ID does not match its action.' }
    if ($item.action -eq 'move-review') {
      $relative=$file.FullName.Substring($targetRoot.Length)
      $destination=Join-Path (Join-Path $moveFull ('drive-quarantine-'+$stamp)) $relative
      if (Test-Path -LiteralPath $destination) { throw 'Destination already exists.' }
      if ($Execute) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        $sourceHash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $copyStarted=$true
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        $copied=Get-Item -LiteralPath $destination -Force
        $destinationHash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        $sourceHashAfter=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ([long]$copied.Length -ne [long]$file.Length -or $destinationHash -ne $sourceHash -or $sourceHashAfter -ne $sourceHash) { throw 'Copy verification failed; source was preserved.' }
        Remove-Item -LiteralPath $file.FullName -Force
        $copyStarted=$false
        $status='moved'; $message='Copied, SHA-256 verified, then removed from source.'
      }
    } elseif ($item.action -eq 'delete-low-risk') {
      if ($Execute) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($file.FullName,'OnlyErrorDialogs','SendToRecycleBin')
        $status='recycled'; $message='Sent to Recycle Bin.'
      }
    } else { throw 'Unsupported manifest action.' }
  } catch {
    if ($copyStarted -and $destination -and (Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $item.path)) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
    $status='skipped'; $message=$_.Exception.Message
  }
  $results.Add([pscustomobject]@{id=$item.id;path=$item.path;action=$item.action;status=$status;destination=$destination;message=$message;bytes=$item.bytes})
}
$results | Format-Table -AutoSize
if ([string]::IsNullOrWhiteSpace($ResultPath)) { $ResultPath=Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($Manifest))) ('drive-operation-'+$stamp+'.json') }
$resultFull=[IO.Path]::GetFullPath($ResultPath)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resultFull) | Out-Null
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $resultFull -Encoding UTF8
Write-Output ('Operation report: '+$resultFull)
