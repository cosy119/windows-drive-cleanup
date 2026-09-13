[CmdletBinding()]
param(
  [ValidatePattern('^[A-Za-z]:\\?$')][string]$DriveRoot = 'C:\',
  [string]$OutputDirectory = (Join-Path $PWD 'classify-audit'),
  [int]$TempMinimumAgeDays = 7,
  [long]$MoveMinimumBytes = 268435456,
  [int]$MoveMinimumAgeDays = 30,
  [int]$TopExamples = 10,
  [int]$TopRollupDirs = 15,
  [int]$RollupDepth = 6,
  [int]$MaxScanSeconds = 1800,
  [int]$MaxConfigFiles = 3000,
  [int]$MaxScanErrors = 20000,
  [switch]$SkipReferenceScan,
  [switch]$WriteDetailCsv
)

$ErrorActionPreference = 'Stop'

# Bucket identifiers stay ASCII: repository validation rejects non-ASCII script text,
# and Windows PowerShell 5.1 misdecodes BOM-less UTF-8 files on non-UTF8 codepages.
$BUCKETS = @('safe-delete','regenerable','keep','safe-move','move-needs-repoint','cannot-move')

$driveFull = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($DriveRoot))
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $outputFull | Out-Null

# Existence baseline: only files that already existed when the command started are in scope.
$scanStart = Get-Date
$scanStartUtc = $scanStart.ToUniversalTime()
$timer = [Diagnostics.Stopwatch]::StartNew()
$timeLimit = $false

$allowedExt = @(
  '.zip','.7z','.rar','.tar','.gz','.iso','.img','.mp4','.mkv','.mov','.avi','.webm',
  '.mp3','.wav','.flac','.jpg','.jpeg','.png','.gif','.webp','.tif','.tiff','.pdf',
  '.doc','.docx','.ppt','.pptx','.xls','.xlsx','.exe','.msi'
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Test-UnderRoot([string]$Path,[string]$Root) {
  if (-not $Root) { return $false }
  $full = [IO.Path]::GetFullPath($Path)
  $base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
  return $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)
}

function Get-RollupKey([string]$Directory,[int]$Depth) {
  if (-not $Directory) { return '(unknown)' }
  $parts = $Directory.Split('\')
  if ($parts.Count -le $Depth) { return $Directory }
  return ($parts[0..($Depth-1)] -join '\')
}

function New-CombinedRegex([string[]]$Patterns,[string]$Name) {
  if (-not $Patterns -or $Patterns.Count -eq 0) { return $null }
  $body = ($Patterns | ForEach-Object { '(?:' + $_ + ')' }) -join '|'
  return [regex]::new($body,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-PathTokens([string]$Text) {
  $out = New-Object 'System.Collections.Generic.List[string]'
  if ([string]::IsNullOrWhiteSpace($Text)) { return $out }
  foreach ($m in [regex]::Matches($Text,'[A-Za-z]:\\[^";|<>*?\r\n]{2,240}')) {
    $v = $m.Value.Trim().TrimEnd('\').TrimEnd('.')
    if ($v.Length -gt 3) { [void]$out.Add($v) }
  }
  return $out
}

# ---------------------------------------------------------------------------
# Reference collection (lightweight)
# ---------------------------------------------------------------------------

$refFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$refDirs  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$refNote  = @{}
$refStats = [ordered]@{}
$refWarnings = New-Object 'System.Collections.Generic.List[string]'

function Add-RefNote([string]$Key,[string]$Note) {
  if (-not $Key) { return }
  if (-not $script:refNote.ContainsKey($Key)) { $script:refNote[$Key] = $Note }
}

function Add-RefPath([string]$Path,[string]$Source,[switch]$AsDirectory) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  $p = $Path.Trim().Trim('"').TrimEnd('\')
  if ($p.Length -lt 4) { return }
  if ($p -notmatch '^[A-Za-z]:\\') { return }
  if ($AsDirectory) {
    [void]$script:refDirs.Add($p)
    Add-RefNote $p $Source
  } else {
    $isDir = $false
    try { if ([IO.Directory]::Exists($p)) { $isDir = $true } } catch { $isDir = $false }
    if ($isDir) {
      [void]$script:refDirs.Add($p)
      Add-RefNote $p $Source
    } else {
      [void]$script:refFiles.Add($p)
      Add-RefNote $p $Source
    }
  }
}

function Add-RefText([string]$Text,[string]$Source) {
  foreach ($t in (Get-PathTokens $Text)) { Add-RefPath $t $Source }
}

if (-not $SkipReferenceScan) {

  # 1) Shortcuts
  $lnkDirs = @(
    (Join-Path $env:USERPROFILE 'Desktop'),
    (Join-Path $env:PUBLIC 'Desktop'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu'),
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch')
  )
  $lnkCount = 0
  $wsh = $null
  try { $wsh = New-Object -ComObject WScript.Shell } catch { $wsh = $null }
  if (-not $wsh) { [void]$refWarnings.Add('COM unavailable: shortcut targets resolved by byte scan only') }
  foreach ($d in $lnkDirs) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
    foreach ($lnk in (Get-ChildItem -LiteralPath $d -Filter '*.lnk' -File -Recurse -Force -ErrorAction SilentlyContinue)) {
      $lnkCount++
      $src = 'shortcut:' + $lnk.FullName
      if ($wsh) {
        try {
          $sc = $wsh.CreateShortcut($lnk.FullName)
          Add-RefPath ([string]$sc.TargetPath) $src
          Add-RefPath ([string]$sc.WorkingDirectory) ($src + ' workdir') -AsDirectory
          Add-RefText ([string]$sc.Arguments) $src
        } catch { [void]$refWarnings.Add('shortcut parse failed: ' + $lnk.FullName) }
      } else {
        try {
          $raw = [IO.File]::ReadAllBytes($lnk.FullName)
          Add-RefText ([Text.Encoding]::ASCII.GetString($raw)) $src
          Add-RefText ([Text.Encoding]::Unicode.GetString($raw)) $src
        } catch {}
      }
    }
  }
  $refStats['shortcuts'] = $lnkCount

  # 2) PATH entries
  $pathEntries = @(($env:PATH -split ';') | Where-Object { $_ } | ForEach-Object { $_.Trim().Trim('"').TrimEnd('\') })
  foreach ($e in $pathEntries) { Add-RefPath $e 'PATH entry' -AsDirectory }
  $refStats['pathEntries'] = $pathEntries.Count

  # 3) Registry
  $uninstallCount = 0
  foreach ($r in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )) {
    foreach ($item in (Get-ItemProperty -Path $r -ErrorAction SilentlyContinue)) {
      $uninstallCount++
      foreach ($field in @('InstallLocation','DisplayIcon','UninstallString','InstallSource','QuietUninstallString')) {
        $v = $null
        try { $v = [string]$item.$field } catch { $v = $null }
        if ($v) { Add-RefText $v ('registry:uninstall/' + $field) }
      }
    }
  }
  $refStats['uninstallEntries'] = $uninstallCount

  $runCount = 0
  foreach ($rk in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
  )) {
    $props = Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue
    if ($props) {
      foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        $runCount++
        Add-RefText ([string]$p.Value) ('registry:run/' + $rk.Split('\')[-1])
      }
    }
  }
  $refStats['runKeyValues'] = $runCount

  foreach ($sf in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
  )) {
    $props = Get-ItemProperty -Path $sf -ErrorAction SilentlyContinue
    if ($props) {
      foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        $val = [string]$p.Value
        if ($val -and $val -match '^[A-Za-z]:\\') { Add-RefPath $val 'registry:shell-folder' -AsDirectory }
      }
    }
  }

  foreach ($ek in @(
    'HKCU:\Environment',
    'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  )) {
    $props = Get-ItemProperty -Path $ek -ErrorAction SilentlyContinue
    if ($props) {
      foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        Add-RefText ([string]$p.Value) ('registry:env/' + $p.Name)
      }
    }
  }

  # 4) Services
  $svcCount = 0
  try {
    foreach ($s in (Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
      if ($s.PathName) { $svcCount++; Add-RefText ([string]$s.PathName) ('service:' + $s.Name) }
    }
  } catch { [void]$refWarnings.Add('service enumeration failed: ' + $_.Exception.Message) }
  $refStats['services'] = $svcCount

  # 5) Scheduled tasks
  $taskCount = 0
  try {
    foreach ($t in (Get-ScheduledTask -ErrorAction Stop)) {
      foreach ($a in @($t.Actions)) {
        if ($a.Execute) {
          $taskCount++
          Add-RefText ([string]$a.Execute) ('scheduled-task:' + $t.TaskName)
          Add-RefText ([string]$a.Arguments) ('scheduled-task:' + $t.TaskName)
          Add-RefText ([string]$a.WorkingDirectory) ('scheduled-task:' + $t.TaskName)
        }
      }
    }
  } catch { [void]$refWarnings.Add('scheduled task enumeration failed: ' + $_.Exception.Message) }
  $refStats['scheduledTasks'] = $taskCount

  # 6) Common configuration files (bounded count, bounded size)
  $cfgNames = @('.env','.gitconfig','package.json','pyvenv.cfg','settings.json','tasks.json',
                'launch.json','.code-workspace','.sln','.csproj','.vcxproj','.pyproj','.pro','.iml')
  $cfgExts = @('.sln','.csproj','.vcxproj','.pyproj','.iml')
  $cfgCount = 0
  foreach ($root in @(
    (Join-Path $env:USERPROFILE 'Documents'),
    (Join-Path $env:USERPROFILE 'Desktop'),
    (Join-Path $env:USERPROFILE 'Downloads')
  )) {
    if ($cfgCount -ge $MaxConfigFiles) { break }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)) {
      if ($cfgCount -ge $MaxConfigFiles) { break }
      if ($timer.Elapsed.TotalSeconds -ge $MaxScanSeconds) { break }
      $isCfg = ($cfgNames -contains $f.Name) -or ($cfgExts -contains $f.Extension.ToLowerInvariant())
      if (-not $isCfg) { continue }
      if (-not (Test-UnderRoot $f.FullName $driveFull)) { continue }
      $cfgCount++
      try {
        if ($f.Length -le 2097152) { Add-RefText ([IO.File]::ReadAllText($f.FullName)) ('config:' + $f.FullName) }
      } catch {}
    }
  }
  $refStats['configFilesRead'] = $cfgCount
}

function Get-ReferenceFor([string]$Path) {
  if ($refNote.ContainsKey($Path)) { return $refNote[$Path] }
  $dir = Split-Path -Path $Path -Parent
  while ($dir -and $dir.Length -gt 3) {
    if ($refNote.ContainsKey($dir)) { return ($refNote[$dir] + ' (parent dir)') }
    $parent = Split-Path -Path $dir -Parent
    if (-not $parent -or $parent -eq $dir) { break }
    $dir = $parent
  }
  return $null
}

# ---------------------------------------------------------------------------
# Classification patterns
# ---------------------------------------------------------------------------

# Roots that must never be treated as cache or temp, whatever else a path matches.
# WinSxS cleanup requires DISM; Program Files and ProgramData are off-limits.
$rxHardProtected = New-CombinedRegex @(
  '\\WinSxS\\',
  '\\Program Files\\',
  '\\Program Files \(x86\)\\',
  '\\System Volume Information\\',
  '\\\$Recycle\.Bin\\',
  '\\Recovery\\',
  '\\Boot\\',
  '\\EFI\\'
) 'hard-protected'

$rxSafeDelete = New-CombinedRegex @(
  '\\AppData\\Local\\Temp\\',
  '\\Windows\\Temp\\',
  '\\Windows\\SystemTemp\\',
  '\\ProgramData\\Microsoft\\Windows\\WER\\',
  '\\AppData\\Local\\Microsoft\\Windows\\WER\\',
  '\\AppData\\Local\\CrashDumps\\',
  '\\Windows\\Minidump\\',
  '\\Windows\\LiveKernelReports\\',
  '\\Windows\\Logs\\',
  '\\Windows\\Panther\\',
  '\\Windows\\INF\\setupapi\.(dev|app)\.log$',
  '\\Windows\\SoftwareDistribution\\DataStore\\Logs\\',
  '\\ServiceProfiles\\.*\\AppData\\Local\\Temp\\'
) 'safe-delete'

$rxRegenerable = New-CombinedRegex @(
  '\\AppData\\Local\\pip\\cache',
  '\\AppData\\Local\\npm-cache',
  '\\AppData\\Roaming\\npm-cache',
  '\\AppData\\Local\\Yarn\\Cache',
  '\\AppData\\Local\\pnpm-store',
  '\\AppData\\Local\\NuGet\\v3-cache',
  '\\AppData\\Local\\NuGet\\Cache',
  '\\User Data\\.*\\Cache',
  '\\User Data\\.*\\Code Cache',
  '\\User Data\\.*\\GPUCache',
  '\\User Data\\.*\\Service Worker\\.*Cache',
  '\\AppData\\Local\\Microsoft\\Windows\\INetCache\\',
  '\\AppData\\Local\\Microsoft\\Windows\\WebCache\\',
  '\\AppData\\Local\\D3DSCache\\',
  '\\AppData\\Local\\NVIDIA\\DXCache\\',
  '\\AppData\\Local\\NVIDIA\\GLCache\\',
  '\\AppData\\Local\\AMD\\DxCache\\',
  '\\AppData\\Local\\AMD\\DxcCache\\',
  '\\AppData\\Local\\Microsoft\\Windows\\Explorer\\thumbcache_',
  '\\AppData\\Local\\Microsoft\\Windows\\Explorer\\iconcache_',
  '\\AppData\\Local\\Microsoft\\VisualStudio\\.*Cache',
  '\\AppData\\Local\\Microsoft\\VSCommon\\.*Cache',
  '\\AppData\\Local\\JetBrains\\.*\\caches',
  '\\Windows\\Prefetch\\',
  '\\Windows\\SoftwareDistribution\\Download\\',
  '\\ProgramData\\Microsoft\\Windows\\Caches\\',
  '\\Scans\\History\\',
  '\\AppData\\Local\\Microsoft\\Windows\\FontCache'
) 'regenerable'

$rxProtected = New-CombinedRegex @(
  '\\Windows\\',
  '\\Program Files\\',
  '\\Program Files \(x86\)\\',
  '\\ProgramData\\',
  '\\System Volume Information\\',
  '\\Recovery\\',
  '\\Boot\\',
  '\\EFI\\',
  '\\Users\\.*\\NTUSER\.DAT',
  '\\Users\\.*\\UsrClass\.dat',
  '\\pagefile\.sys$',
  '\\hiberfil\.sys$',
  '\\swapfile\.sys$',
  '\\DumpStack\.log\.tmp$'
) 'protected'

$userContentRoots = @()
foreach ($n in @('Downloads','Documents','Desktop','Videos','Music','Pictures','Favorites','Links')) {
  $userContentRoots += (Join-Path $env:USERPROFILE $n)
}

$excludedOnAnyDrive = [regex]::new(
  '[\\/](Windows|Program Files|Program Files \(x86\)|ProgramData|Recovery|System Volume Information|\$Recycle\.Bin|AppData|node_modules|\.git)([\\/]|$)',
  [Text.RegularExpressions.RegexOptions]::IgnoreCase)

$cloudRoots = @(
  $env:OneDrive,$env:OneDriveConsumer,$env:OneDriveCommercial,
  (Join-Path $env:USERPROFILE 'Dropbox'),
  (Join-Path $env:USERPROFILE 'Google Drive'),
  (Join-Path $env:USERPROFILE 'iCloudDrive'),
  (Join-Path $env:USERPROFILE 'Box'),
  (Join-Path $env:USERPROFILE 'Nutstore')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique

$cutoffTemp = $scanStart.AddDays(-$TempMinimumAgeDays)
$cutoffMove = $scanStart.AddDays(-$MoveMinimumAgeDays)

function Test-InCloudRoot([string]$Path) {
  foreach ($c in $cloudRoots) { if (Test-UnderRoot $Path $c) { return $true } }
  return $false
}

function Test-IsMoveCandidate([IO.FileInfo]$File,[string]$Path) {
  if ($File.Length -lt $MoveMinimumBytes) { return $false }
  if ($File.LastWriteTime -gt $cutoffMove) { return $false }
  if ($allowedExt -notcontains $File.Extension.ToLowerInvariant()) { return $false }
  if ($driveFull -eq 'C:\') {
    foreach ($r in $userContentRoots) { if (Test-UnderRoot $Path $r) { return $true } }
    return $false
  }
  if ($Path -match '[\\/]\.git[\\/]') { return $false }
  return (-not $excludedOnAnyDrive.IsMatch($Path))
}

function Test-Locked([string]$Path) {
  try {
    $s = [IO.File]::Open($Path,'Open','Read','ReadWrite')
    $s.Dispose()
    return $false
  } catch { return $true }
}

# ---------------------------------------------------------------------------
# Aggregation state (bounded)
# ---------------------------------------------------------------------------

$counts = @{}
$bytes  = @{}
$reasons = @{}
$rollup = @{}
$topK = @{}
$topSeq = 0L
foreach ($b in $BUCKETS) {
  $counts[$b] = 0L
  $bytes[$b] = 0L
  $reasons[$b] = @{}
  $rollup[$b] = @{}
  $topK[$b] = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)
}

$skippedDuringScan = 0L
$inaccessibleDirs = 0L
$linkDirsSkipped = 0L
$dirsScanned = 0L

function Add-Record([string]$Bucket,[IO.FileInfo]$File,[string]$Reason,[string]$Note) {
  $script:counts[$Bucket]++
  $script:bytes[$Bucket] += [long]$File.Length

  if (-not $script:reasons[$Bucket].ContainsKey($Reason)) { $script:reasons[$Bucket][$Reason] = @{ c=0L; b=0L } }
  $script:reasons[$Bucket][$Reason].c++
  $script:reasons[$Bucket][$Reason].b += [long]$File.Length

  $dir = Split-Path -Path $File.FullName -Parent
  $key = Get-RollupKey $dir $RollupDepth
  if (-not $script:rollup[$Bucket].ContainsKey($key)) { $script:rollup[$Bucket][$key] = @{ c=0L; b=0L } }
  $script:rollup[$Bucket][$key].c++
  $script:rollup[$Bucket][$key].b += [long]$File.Length

  if ($TopExamples -gt 0) {
    $script:topSeq++
    $sortKey = ([long]$File.Length).ToString('D20') + ':' + $script:topSeq.ToString('D20')
    $script:topK[$Bucket].Add($sortKey,[pscustomobject]@{
      path=$File.FullName; bytes=[long]$File.Length; reason=$Reason; note=$Note
      lastWriteUtc=$File.LastWriteTimeUtc.ToString('o')
    })
    if ($script:topK[$Bucket].Count -gt $TopExamples) {
      $e = $script:topK[$Bucket].Keys.GetEnumerator()
      [void]$e.MoveNext()
      [void]$script:topK[$Bucket].Remove($e.Current)
    }
  }
}

$detail = $null
if ($WriteDetailCsv) { $detail = New-Object 'System.Collections.Generic.List[object]' }

# ---------------------------------------------------------------------------
# Main enumeration: manual stack traversal keeps memory bounded and lets the
# time limit take effect immediately (Get-ChildItem -Recurse would buffer every
# FileInfo object first).
# ---------------------------------------------------------------------------

$pending = New-Object 'System.Collections.Generic.Stack[string]'
$pending.Push($driveFull)

while ($pending.Count -gt 0) {
  if ($timer.Elapsed.TotalSeconds -ge $MaxScanSeconds) { $timeLimit = $true; break }
  $dir = $pending.Pop()
  $dirsScanned++

  $filePaths = $null
  try { $filePaths = [IO.Directory]::GetFiles($dir) }
  catch {
    if ($inaccessibleDirs -lt $MaxScanErrors) { $inaccessibleDirs++ }
    $filePaths = $null
  }

  if ($filePaths) {
    foreach ($fp in $filePaths) {
      if ($timer.Elapsed.TotalSeconds -ge $MaxScanSeconds) { $timeLimit = $true; break }

      $fi = $null
      try { $fi = New-Object IO.FileInfo $fp } catch { continue }
      if (-not $fi.Exists) { continue }

      if ($fi.CreationTimeUtc -gt $scanStartUtc) { $skippedDuringScan++; continue }

      $attrs = $fi.Attributes
      $bucket = $null
      $reason = $null
      $note = $null

      if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $bucket = 'cannot-move'; $reason = 'reparse-point'
      } elseif (Test-InCloudRoot $fp) {
        $bucket = 'cannot-move'; $reason = 'sync-managed-location'
      } elseif ($rxHardProtected.IsMatch($fp)) {
        $bucket = 'keep'; $reason = 'hard-protected'
      } elseif ($rxSafeDelete.IsMatch($fp)) {
        if ($fi.LastWriteTime -lt $cutoffTemp) { $bucket = 'safe-delete'; $reason = 'temp-or-diagnostic' }
        else { $bucket = 'keep'; $reason = 'temp-but-recent' }
      } elseif ($rxRegenerable.IsMatch($fp)) {
        if ($fi.LastWriteTime -lt $cutoffTemp) { $bucket = 'regenerable'; $reason = 'cache-regenerates' }
        else { $bucket = 'keep'; $reason = 'cache-but-recent' }
      } elseif (Test-IsMoveCandidate $fi $fp) {
        if (Test-Locked $fp) {
          $bucket = 'cannot-move'; $reason = 'file-in-use'
        } else {
          $ref = Get-ReferenceFor $fp
          if ($ref) { $bucket = 'move-needs-repoint'; $reason = 'referenced'; $note = $ref }
          else { $bucket = 'safe-move'; $reason = 'user-content-unreferenced' }
        }
      } elseif ($rxProtected.IsMatch($fp)) {
        $bucket = 'keep'; $reason = 'protected-location'
      } else {
        $bucket = 'keep'; $reason = 'unclassified-fallback'
      }

      Add-Record $bucket $fi $reason $note
      if ($detail) {
        $detail.Add([pscustomobject]@{
          bucket=$bucket; reason=$reason; path=$fp; bytes=[long]$fi.Length
          lastWriteUtc=$fi.LastWriteTimeUtc.ToString('o'); note=$note
        })
      }
    }
  }

  $subDirs = $null
  try { $subDirs = [IO.Directory]::GetDirectories($dir) }
  catch {
    if ($inaccessibleDirs -lt $MaxScanErrors) { $inaccessibleDirs++ }
    $subDirs = $null
  }

  if ($subDirs) {
    foreach ($sd in $subDirs) {
      try {
        if (([IO.File]::GetAttributes($sd) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $linkDirsSkipped++; continue }
      } catch { continue }
      $pending.Push($sd)
    }
  }
}

$timer.Stop()

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

$totalFiles = 0L; $totalBytes = 0L
foreach ($b in $BUCKETS) { $totalFiles += $counts[$b]; $totalBytes += $bytes[$b] }

$summary = [ordered]@{
  schemaVersion = 1
  driveRoot = $driveFull
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  baseline = @{
    commandStartedUtc = $scanStartUtc.ToString('o')
    note = 'only files whose creation time precedes the command start are counted'
    createdDuringScanExcluded = $skippedDuringScan
  }
  parameters = @{
    tempMinimumAgeDays = $TempMinimumAgeDays
    moveMinimumBytes = $MoveMinimumBytes
    moveMinimumAgeDays = $MoveMinimumAgeDays
    rollupDepth = $RollupDepth
    referenceScan = (-not $SkipReferenceScan)
  }
  scan = @{
    seconds = [Math]::Round($timer.Elapsed.TotalSeconds,2)
    timeLimitReached = [bool]$timeLimit
    directoriesScanned = $dirsScanned
    inaccessibleDirectories = $inaccessibleDirs
    linkDirectoriesSkipped = $linkDirsSkipped
  }
  totals = @{ files = $totalFiles; bytes = $totalBytes }
  referenceSources = $refStats
  referenceWarnings = @($refWarnings)
  buckets = @()
}

foreach ($b in $BUCKETS) {
  $reasonList = @()
  foreach ($k in ($reasons[$b].Keys | Sort-Object { -$reasons[$b][$_].b })) {
    $reasonList += [pscustomobject]@{ reason=$k; files=$reasons[$b][$k].c; bytes=$reasons[$b][$k].b }
  }
  $dirList = @()
  foreach ($k in ($rollup[$b].Keys | Sort-Object { -$rollup[$b][$_].b } | Select-Object -First $TopRollupDirs)) {
    $dirList += [pscustomobject]@{ directory=$k; files=$rollup[$b][$k].c; bytes=$rollup[$b][$k].b }
  }
  $exampleList = @()
  foreach ($obj in $topK[$b].Values) { $exampleList += $obj }
  $exampleList = @($exampleList | Sort-Object @{Expression='bytes';Descending=$true})

  $summary.buckets += [pscustomobject]@{
    bucket = $b
    files = $counts[$b]
    bytes = $bytes[$b]
    reasons = $reasonList
    topDirectories = $dirList
    topFiles = $exampleList
  }
}

function Format-Size([double]$Bytes) {
  if ($Bytes -ge 1073741824) { return ('{0:N2} GiB' -f ($Bytes / 1073741824)) }
  if ($Bytes -ge 1048576)    { return ('{0:N1} MiB' -f ($Bytes / 1048576)) }
  if ($Bytes -ge 1024)       { return ('{0:N1} KiB' -f ($Bytes / 1024)) }
  return ('{0} B' -f [int]$Bytes)
}

$jsonPath = Join-Path $outputFull 'classify-summary.json'
$mdPath = Join-Path $outputFull 'classify-report.md'
($summary | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$csvPath = $null
if ($detail) {
  $csvPath = Join-Path $outputFull 'classify-detail.csv'
  $detail | Select-Object bucket,reason,path,bytes,lastWriteUtc,note |
    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
}

$refModeText = 'lightweight (shortcuts, PATH, registry, services, tasks, config files)'
if ($SkipReferenceScan) { $refModeText = 'disabled' }

$lines = @()
$lines += '# Drive classification audit: ' + $driveFull
$lines += ''
$lines += 'Read-only. No files were moved or deleted.'
$lines += ''
$lines += 'Baseline: files existing before the command started (creation time earlier than ' + $scanStartUtc.ToString('o') + '). Files created during the scan were excluded: ' + $skippedDuringScan + '.'
$lines += 'Scan seconds: ' + [Math]::Round($timer.Elapsed.TotalSeconds,2) + '; directories scanned: ' + $dirsScanned + '; inaccessible directories: ' + $inaccessibleDirs + '; link directories skipped: ' + $linkDirsSkipped + '.'
$lines += 'Reference detection: ' + $refModeText + '.'
if ($timeLimit) { $lines += ''; $lines += '**Scan time limit reached; results are partial.** Increase -MaxScanSeconds for a complete pass.' }
$lines += ''
$lines += 'Total files: ' + $totalFiles + ' (' + (Format-Size $totalBytes) + ')'
$lines += ''
$lines += '| Bucket | Files | Size | Share |'
$lines += '|---|---:|---:|---:|'
foreach ($b in $summary.buckets) {
  $share = '0%'
  if ($totalBytes -gt 0) { $share = ('{0:N1}%' -f (100.0 * $b.bytes / $totalBytes)) }
  $lines += ('| ' + $b.bucket + ' | ' + $b.files + ' | ' + (Format-Size $b.bytes) + ' | ' + $share + ' |')
}
$lines += ''

foreach ($b in $summary.buckets) {
  $lines += '## ' + $b.bucket
  $lines += ''
  if ($b.files -eq 0) { $lines += 'No files in this bucket.'; $lines += ''; continue }
  $lines += '| Reason | Files | Size |'
  $lines += '|---|---:|---:|'
  foreach ($r in ($b.reasons | Select-Object -First 12)) {
    $lines += ('| ' + $r.reason + ' | ' + $r.files + ' | ' + (Format-Size $r.bytes) + ' |')
  }
  $lines += ''
  $lines += 'Top directories (rolled up to ' + $RollupDepth + ' path segments):'
  $lines += ''
  $lines += '| Directory | Files | Size |'
  $lines += '|---|---:|---:|'
  foreach ($d in $b.topDirectories) {
    $lines += ('| <code>' + [Net.WebUtility]::HtmlEncode($d.directory) + '</code> | ' + $d.files + ' | ' + (Format-Size $d.bytes) + ' |')
  }
  $lines += ''
  $lines += 'Largest files:'
  $lines += ''
  $lines += '| Size | Last write (UTC) | Path | Note |'
  $lines += '|---:|---|---|---|'
  foreach ($x in $b.topFiles) {
    $enc = [Net.WebUtility]::HtmlEncode($x.path)
    $nt = ''
    if ($x.note) { $nt = [Net.WebUtility]::HtmlEncode($x.note) }
    $lines += ('| ' + (Format-Size $x.bytes) + ' | ' + $x.lastWriteUtc + ' | <code>' + $enc + '</code> | ' + $nt + ' |')
  }
  $lines += ''
}

$lines += '## Reference sources'
$lines += ''
foreach ($k in $refStats.Keys) { $lines += '- ' + $k + ': ' + $refStats[$k] }
if (@($refWarnings).Count) {
  $lines += ''
  $lines += 'Warnings:'
  foreach ($w in $refWarnings) { $lines += '- ' + $w }
}

$lines | Set-Content -LiteralPath $mdPath -Encoding UTF8

Write-Output ('Summary JSON : ' + $jsonPath)
Write-Output ('Report MD    : ' + $mdPath)
if ($csvPath) { Write-Output ('Detail CSV   : ' + $csvPath) }
Write-Output ''

$table = @()
foreach ($b in $summary.buckets) {
  $table += [pscustomobject]@{ bucket = $b.bucket; files = $b.files; size = (Format-Size $b.bytes) }
}
$table | Format-Table -AutoSize
Write-Output ('TOTAL files: ' + $totalFiles + ' (' + (Format-Size $totalBytes) + ')  seconds: ' + [Math]::Round($timer.Elapsed.TotalSeconds,2))
