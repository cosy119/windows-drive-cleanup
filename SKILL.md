---
name: windows-drive-cleanup
description: "Audit a user-selected Windows drive and prepare reviewable candidates for low-risk relocation or cleanup. Use when the user wants to inspect or free disk space. Always scan read-only first and require explicit item-level approval before mutation."
---

# Windows Drive Cleanup

Reduce usage on a selected local Windows drive without silently changing the system or applications. Default to `C:\`, but honor a drive the user names in conversation, such as `D:\`. Never promise that moving or deleting arbitrary files has zero effect. Establish confidence from location, type, age, ownership, current use, and documented purpose, then state the remaining uncertainty.

## Workflow

1. Resolve the target from the conversation. Use `C:\` only when the user has not chosen another local drive. Repeat the resolved drive in the audit heading. Treat links, junctions, cloud placeholders, encrypted files, and files owned by another account as out of scope.
2. Run `scripts/scan-drive.ps1 -DriveRoot <drive>` without elevation. Discovery must be read-only. Save its JSON, CSV, and Markdown reports in a user-writable directory. The scan records size and timestamp only; SHA-256 is deferred until the user approves an actual move.
3. Read [references/classification.md](references/classification.md) before interpreting results. Supplement the script with read-only disk-usage checks when useful.
4. Respond in chat. Do not give the user Markdown, CSV, JSON, or Word reports unless they explicitly ask for a file. The JSON manifest remains an internal execution input.
5. Group results by `sourceGroup` and present simple group numbers `1`, `2`, `3`, and so on. Show path, file count, total size, assessment breakdown, and risk for each group. Let the user approve group numbers. Do not require internal `D0001` or `M0001` IDs unless they choose only part of a group.
6. Classify every detected file along both dimensions below. Never call an outcome guaranteed or completely impact-free; use high-confidence wording and state residual uncertainty.
   - Deletion: `high-confidence removable`, `confirm before deletion`, `cannot delete`.
   - Transfer: `high-confidence transferable`, `manual confirmation required`, `transfer requires repointing`, `cannot transfer`.
   Map old disposable files under narrowly allowed temp or diagnostic roots to high-confidence removal. Map recent temp files and regenerable caches to confirmation. Map protected, application, active, encrypted, sync-managed, and system content to cannot delete. Use reference-scan evidence to distinguish transferable, confirmation, repointing, and cannot-transfer results.
7. List all detected files in chat under their numbered source groups. When the list is too large for one response, paginate it and clearly state the shown range and remaining count; continue in later messages instead of replacing the list with a document link.
   Always render two explicit sections: `Deletion assessment` and `Transfer assessment`. Show every category with its count, including zero-count categories, so transfer results can never disappear from the response.
8. Ask the user to approve exact group numbers and actions. A request to clean C: authorizes scanning, not mutation. Silence or approval of one group does not approve another.
9. Preview approved groups with `scripts/apply-approved.ps1 -GroupIds <numbers>`. Real execution additionally requires `-Execute -ConfirmToken CONFIRM`.
10. Verify the results. Report successes, changed or skipped files, failures, recovered space, quarantine location, and restoration instructions. Do not stop processes or reboot to unlock files unless separately requested.

## Classification audit (read-only overview)

When the user wants the whole drive classified rather than a candidate list, run `scripts/classify-drive.ps1`. It enumerates every file that existed before the command started and aggregates the result into six exclusive buckets, so the report stays readable instead of listing tens of thousands of rows.

| Bucket | Meaning |
|---|---|
| `safe-delete` | Temporary or diagnostic data under recognised temp roots; no ongoing purpose |
| `regenerable` | Caches rebuilt on demand (package managers, browser caches, shader caches, prefetch) |
| `keep` | Protected system locations, temp or cache entries that are too recent to touch, and everything that could not be classified confidently (conservative default) |
| `safe-move` | Large user-content files that are older than the move threshold and that no detected reference points at |
| `move-needs-repoint` | Same as `safe-move`, but a shortcut, PATH entry, registry value, service, scheduled task, or configuration file references the path, so moving it requires updating that reference |
| `cannot-move` | Reparse points, sync-managed locations, and files held open by another process |

Precedence is evaluated in that order, first match wins. Report per bucket: file count, total size, share, reason breakdown, directory roll-up, and the largest files. Detail rows are written only when `-WriteDetailCsv` is passed.

Reference detection is deliberately lightweight: shortcuts, PATH, uninstall/Run registry values, shell folders, environment values, services, scheduled tasks, and common IDE or project configuration files. It does not scan the whole registry, so an unreferenced verdict is evidence, not proof.

**A `safe-delete` verdict is never a guarantee.** No tool can prove that deleting an arbitrary file has zero effect. Treat the buckets as prioritised evidence: classify first, present the aggregate, and still require explicit approval before any mutation. Scan-time age thresholds (`TempMinimumAgeDays`, `MoveMinimumAgeDays`) and size thresholds decide what counts as actionable, and recent temp or cache entries are deliberately routed to `keep` instead of being called disposable.

## Safety boundaries

- Never move or delete from Windows, Program Files, Program Files (x86), ProgramData, Recovery, System Volume Information, boot folders, driver stores, component stores, installer caches, registry hives, or profile roots. The only Windows-tree exception is an old regular file under the exact `C:\Windows\Temp` root, when it passes the low-risk checks and receives item-level approval.
- Never touch executables used by installed applications, DLLs, drivers, services, scheduled-task payloads, package-manager stores, virtual disks, mail databases, browser profiles, credentials, keys, repositories, databases, or sync-managed files merely because they are old or large.
- Do not use recursive deletion, wildcards for mutations, inferred targets, registry cleaners, ownership or ACL changes, service termination, or `takeown`.
- Keep restore points, hibernation/page files, Windows Update data, and component-store cleanup outside this skill. These require documented system tools and separate intent.
- Preserve any file changed after scanning. The executor verifies size and timestamp before acting. For a move, it copies the approved file, verifies source and destination SHA-256 values, and removes the source only after verification succeeds.
- Move approved files into a uniquely named quarantine folder on a different volume, preserve their relative paths, write a restoration map, and never overwrite. Moving is implemented as verified copy followed by permanent removal of the source path; the source removal does not use the Recycle Bin.
- Send approved deletions to the Recycle Bin. Permanent deletion requires a separate, explicit request after exact-file review.
- Finish the non-admin audit before considering elevation. Never elevate merely to produce more candidates.

## Commands

Read-only scan:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/scan-drive.ps1 -DriveRoot C:\ -OutputDirectory .\drive-audit
```

Read-only scan of all eligible candidates, without age, size, or candidate-count limits:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/scan-drive.ps1 -DriveRoot C:\ -OutputDirectory .\drive-audit -AllCandidates
```

Read-only whole-drive classification:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/classify-drive.ps1 -DriveRoot C:\ -OutputDirectory .\classify-audit
```

Preview exact approved IDs:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/apply-approved.ps1 -Manifest .\drive-audit\drive-candidates.json -Ids "D0001, M0003" -MoveRoot D:\Drive-quarantine
```

Preview approved source groups:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/apply-approved.ps1 -Manifest .\drive-audit\drive-candidates.json -GroupIds "1, 3" -MoveRoot D:\Drive-quarantine
```

Execute after approval:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/apply-approved.ps1 -Manifest .\drive-audit\drive-candidates.json -Ids "D0001, M0003" -MoveRoot D:\Drive-quarantine -Execute -ConfirmToken CONFIRM
```
