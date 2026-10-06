# Vendored Rust compatibility crates

These copies keep Litter's existing transport APIs compatible with the Codex 0.155.1 dependency
graph. They are source copies of the named crates.io releases and retain their upstream licenses.

- `iroh-1.0.3`: keeps Litter on the Iroh API used by the shared mobile bridge. The older
  `iroh-0.98.1` source copy remains only as upgrade history and is no longer referenced.
- `sqlx-0.9.0` and `sqlx-macros-core-0.9.0`: SQLite-only facades. Optional MySQL and PostgreSQL
  dependency blocks are removed so Cargo does not resolve their unused SHA dependency families
  into the same lockfile as Litter's Iroh/SSH stack. The SQLite, macros, and migration surfaces used
  by Codex are unchanged.

When upgrading Codex, first try removing these patches. If upstream dependencies resolve together,
delete the corresponding local overrides rather than carrying the copies forward.
