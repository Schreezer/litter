# Learnfold iOS privacy audit - 2026-08-01

## Release artifact reviewed

- Configuration: signed iOS Release archive
- Bundle identifier: `com.chirag.learnfold`
- Version: `1.5.0 (1)`
- Architecture: `arm64`
- Xcode Organizer export: `output/pdf/Learnfold-Privacy-Report.pdf`

The archive was built with the normal Release link settings after `make ios-release-prep`. Xcode Organizer generated the privacy report from that archive.

## Xcode privacy report result

The generated report contains one collected-data declaration:

- Device ID
  - Tracking: no
  - Linked to the user: yes
  - Purpose: app functionality

The report does not list Required Reason API imports or validate whether every imported API has a matching approved reason. Required Reason APIs therefore need a separate manifest and binary audit.

## Required Reason API manifest

`apps/ios/Sources/Litter/PrivacyInfo.xcprivacy` currently declares:

- File timestamp: `C617.1`
- User defaults: `CA92.1`, `1C8F.1`

No Disk Space reason is declared.

## Release-binary evidence

The archived app's undefined symbols include:

```text
_fstatfs
_fstatvfs
_statfs
```

The imports survive Release dead stripping and therefore must be treated as shipped behavior.

There are two independent sources:

1. Bundled SQLite 3.51.3 imports `statfs` and `fstatfs`. SQLite uses them to inspect filesystem type, read-only state, and locking behavior. It is not querying free capacity for a Learnfold feature.
2. The embedded iSH filesystem bridge object `fs_real.c.o` imports `fstatvfs` for its guest filesystem projection. The currently supported Learnfold product does not expose a user-facing disk-space feature that would justify declaring a Disk Space reason for this import.

The bundled SQLite dependency is intentional. The selected iOS SDK contains SQLite 3.51.0, while the bundled copy is 3.51.3 and includes the upstream WAL-reset corruption fix. Replacing it with the system library solely to remove the imports would regress database safety.

## Decision

Do not add `NSPrivacyAccessedAPICategoryDiskSpace` with reason `E174.1`. The archived uses do not match the approved user-visible disk-space purpose, so adding the reason would make the manifest less accurate.

Before App Store submission, resolve the remaining import gap by one of these truthful paths:

1. Remove the unused iSH/shell runtime from the iOS release link and resource graph, then rebuild and rescan.
2. Patch or configure bundled SQLite so the Apple filesystem-locking checks no longer import covered APIs, but only after database locking and WAL behavior are regression-tested on device.
3. Ask Apple for an approved reason that specifically covers embedded database filesystem and locking detection.

Do not substitute the system SQLite 3.51.0 or claim `E174.1` merely to pass validation.

## Addendum 2026-10-08: RevenueCat SDK (purchases-ios 5.93.0)

The paid-tier work adds RevenueCat as a statically linked SPM dependency. Result: the Required Reason API picture does not change.

- RevenueCat's bundled manifest (`RevenueCat_RevenueCat.bundle/PrivacyInfo.xcprivacy`, copied into the app) declares only User Defaults `CA92.1` and collected Purchase History (App Functionality, not tracking). The app manifest already declares User Defaults `CA92.1`, so the reason set is consistent.
- Scan of the SDK's compiled object (`RevenueCat.o`, simulator Debug build) for covered-API imports: no `stat`/`fstat`/`statfs`/`statvfs`/`getattrlist`, no `mach_absolute_time`/`systemUptime`/boot-time `sysctl`, no volume-capacity or file-timestamp APIs, no active-keyboard APIs. Only UserDefaults use appears. The existing `_fstatfs`/`_fstatvfs`/`_statfs` gap above (SQLite and the iSH bridge) is unchanged and still open.
- This was not a Release archive scan. Re-run the symbol check on the next Release archive before submission.
- App-level `PrivacyInfo.xcprivacy` now also declares User ID and Purchase History as collected, linked, not tracking, App Functionality. The Xcode privacy report for the next archive should list them with Device ID and Product Interaction. The App Store label answers are in `docs/releases/app-review-notes.md`.

## References

- [Apple: Describing data use in privacy manifests](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests)
- [Apple: Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [SQLite: WAL-reset bug](https://www.sqlite.org/wal.html#the_wal_reset_bug)
