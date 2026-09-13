[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Manifest,
  [Parameter(Mandatory)][string[]]$Ids,
  [string]$MoveRoot,
  [switch]$Execute,
  [string]$ConfirmToken,
  [switch]$PermanentDelete
)

$ErrorActionPreference='Stop'
if ($PermanentDelete) { throw 'Permanent deletion is unsupported. Use the Recycle Bin and review it separately.' }
$data = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$targetRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath([string]$data.targetRoot))
$approved = @($data.candidates | Where-Object { $Ids -contains $_.id })
if ($approved.Count -ne $Ids.Count) { throw 'One or more IDs are absent or duplicated in the manifest.' }
if ($Execute -and $ConfirmToken -cne 'CONFIRM') { throw 'Execution requires -ConfirmToken CONFIRM.' }
if ($approved.action -contains 'move-review' -and [string]::IsNullOrWhiteSpace($MoveRoot)) { throw 'MoveRoot is required for move-review items.' }
if ($MoveRoot) {
  $moveFull=[IO.Path]::GetFullPath($MoveRoot)
  if ([IO.Path]::GetPathRoot($moveFull) -eq $targetRoot) { throw 'MoveRoot must be on a different volume from the scanned drive.' }
}
Add-Type -AssemblyName Microsoft.VisualBasic
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$results=[Collections.Generic.List[object]]::new()
foreach($item in $approved){
  $status='preview'; $destination=$null; $message='No change made.'
  try {
    $file=Get-Item -LiteralPath $item.path -Force
    if ([IO.Path]::GetPathRoot($file.FullName) -ne $targetRoot) { throw 'File is outside the manifest target drive.' }
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Not a regular file.' }
    if ([long]$file.Length -ne [long]$item.bytes -or $file.LastWriteTimeUtc.ToString('o') -ne $item.lastWriteUtc) { throw 'File changed after scan.' }
    if ($item.action -eq 'move-review') {
      $relative=$file.FullName.Substring($targetRoot.Length)
      $destination=Join-Path (Join-Path $moveFull ('drive-quarantine-'+$stamp)) $relative
      if (Test-Path -LiteralPath $destination) { throw 'Destination already exists.' }
      if ($Execute) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        $sourceHash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        $copied=Get-Item -LiteralPath $destination -Force
        $destinationHash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        $sourceHashAfter=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ([long]$copied.Length -ne [long]$file.Length -or $destinationHash -ne $sourceHash -or $sourceHashAfter -ne $sourceHash) {
          Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
          throw 'Copy verification failed; source was preserved.'
        }
        Remove-Item -LiteralPath $file.FullName -Force
        $status='moved'; $message='Copied, SHA-256 verified, then removed from source.'
      }
    } elseif ($item.action -eq 'delete-low-risk') {
      if ($Execute) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($file.FullName,'OnlyErrorDialogs','SendToRecycleBin')
        $status='recycled'; $message='Sent to Recycle Bin.'
      }
    } else { throw 'Unsupported manifest action.' }
  } catch { $status='skipped'; $message=$_.Exception.Message }
  $results.Add([pscustomobject]@{id=$item.id;path=$item.path;action=$item.action;status=$status;destination=$destination;message=$message;bytes=$item.bytes})
}
$results | Format-Table -AutoSize
if ($Execute -and $MoveRoot) {
  $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $moveFull ('drive-operation-'+$stamp+'.json')) -Encoding UTF8
}
