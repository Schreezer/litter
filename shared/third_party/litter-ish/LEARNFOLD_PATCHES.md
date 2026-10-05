# Learnfold iSH patch notes

This source snapshot is based on `dnakov/litter-ish` commit
`4f783cd957b83de3019d6a843408d5bb3ff902c7`, the revision previously pinned
in `shared/rust-bridge/Cargo.lock`.

Learnfold carries the following local security/build patches:

- `fs/mount.c`: `mount(2)` and `umount2(2)` require iSH's superuser identity,
  matching the effective Linux `CAP_SYS_ADMIN` boundary. A dropped-uid course
  shell therefore cannot mount arbitrary host paths through realfs.
- `fs/real.c`: realfs opens and retains its mount root before canonicalizing
  it; walks every guest component through directory descriptors with
  `O_NOFOLLOW`; uses the corresponding `*at` operations for mutations; closes
  the retained root on unmount; enforces read-only mount flags; and rejects
  host symlink creation. These are the core concerned-course confinement and
  pre-approval read-only boundaries.
- `fs/sock.c`: non-root course-shell processes cannot create IPv4 or IPv6
  sockets. Unix-domain IPC remains available, while the root-owned general
  iSH runtime retains its existing networking behavior.
- `fs/real.c` also returns synthetic guest filesystem geometry rather than
  importing host `fstatvfs`; native quota enforcement remains authoritative
  and no user-facing host disk-capacity API is exposed through the shell.
- `embed/host/build.rs`: Cargo explicitly watches Meson/C source inputs, so a
  security change to `fs/`, `kernel/`, or another compiled iSH directory cannot
  be omitted from the final static library by a stale Meson archive.
- `tools/staticdefine.sh`: quotes the script directory when including
  `staticdefine.h`. Unquoted, a checkout or Cargo target path containing a
  space silently produced an empty `cpu-offsets.h` and the arm64 gadgets
  failed to assemble.

Regression coverage lives in `apps/ios/Tests/LitterTests/CourseBashToolTests.swift`:
it checks dropped-uid mount denial, final-source-symlink mount denial,
preexisting workspace-symlink rejection, guest symlink-creation denial,
pre-approval read-only behavior, outbound-socket denial, host symlink swap
resistance, mount/root cleanup, and repeated resource-bound behavior. `make rust-ios-sim-fast` must visibly
recompile `ish-embed-host` after any of the C inputs above change.

The vendored tree contains only the source and build inputs required by the
`ish-embed-host` Cargo package; unrelated app, documentation, and Linux-kernel
submodule assets are intentionally omitted.
