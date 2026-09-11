# Candidate classification

Location is evidence, not proof of zero impact. Use `low risk based on current evidence`, never `guaranteed safe`.

## Delete-low-risk

Only include regular, non-reparse files older than the configured threshold from recognized temporary or diagnostic roots that are located on the selected drive. On C:, these may include the current user's resolved temporary directory, `C:\Windows\Temp` when readable, current-user Windows Error Reporting archives/queues, and the current-user CrashDumps directory.

Possible impact: loss of temporary recovery data, cached diagnostics, or unfinished-session artifacts. Exclude recent, open, inaccessible, system, encrypted, sparse, offline, and cloud-placeholder files, and any canonical path that escapes its allowed root.

## Move-review

Limit discovery to large regular user-content files beneath Downloads, Documents, Desktop, Videos, Music, and Pictures. Prefer video, audio, images, documents, archives, disk images, and downloaded installers. Exclude reparse points, `.git`, hidden/system files, cloud-sync roots, packages, databases, and application data.

Moving a file can break shortcuts, recent-file entries, project references, media libraries, or application workflows. Require exact approval and use quarantine.

## Always exclude

- `C:\Windows`, Program Files, Program Files (x86), ProgramData, Recovery, System Volume Information, `$Recycle.Bin`, and files at the volume root.
- Broad AppData trees, browser profiles, package caches, game libraries, dependency trees, source repositories, virtual environments, mail stores, and unknown-format files.
- Application/runtime formats and data such as DLL, SYS, OCX, CPL, registry hives, certificates, keys, active VHD/VHDX, PST/OST, and databases.
- Reparse, offline, system, encrypted, sparse, device, or inaccessible files.

Only the file's creator or owning software can fully establish whether it is still needed.
