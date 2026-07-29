# ADR 0001: Raft storage on a persistentDir; snapshots are the backup

Status: accepted (2026-07-29)

## Context

OpenBao's `file` storage backend is deprecated in v2.6.0 and removed in
v2.7.0, and is documented as non-transactional and unfit for production.
Integrated raft storage is upstream's only production backend, so the choice
of backend is forced. Raft stores data in bbolt, which mmaps its database
file, and the raft layer creates and removes internal snapshot directories.

Cloudron's filesystem backup copies `/app/data` while the app is live. Two
separate hazards follow for a live embedded store:

1. A live copy of a bbolt database is not crash-consistent; the failure is
   silent until restore.
2. Cloudron's backup walker is not resilient to directories that vanish
   mid-walk; on Cloudron 9.1.x a vanished temp directory has aborted an
   entire server's backup run, not just the app's (observed on a live box
   with a bundled analytical store; the raft snapshot directories'
   create-rename-reap lifecycle has the same shape).

Upstream's supported backup mechanism is `bao operator raft snapshot save`,
and their separately shipped snapshot agent confirms file copies are not the
sanctioned route.

## Decision

* `storage "raft"` at `/app/openbao/data`, `node_id` fixed, single node,
  `cluster_addr` on localhost.
* `/app/openbao` is declared in `persistentDirs`: it survives restarts and
  updates but is excluded from the filesystem backup entirely. Both hazards
  are removed structurally rather than mitigated.
* A scheduler task takes an hourly raft snapshot into `/app/data/snapshots`
  (atomic rename, newest 24 kept), and the manifest `backupCommand` tries to
  take a fresh snapshot at backup time (best effort: it runs in a temporary
  container where the live server is not on localhost, so it tries the
  public origin and exits 0 regardless).
* On boot, an empty raft store next to existing snapshots is treated as a
  restore: the package initialises a scratch cluster, restores the newest
  snapshot with `-force`, and verifies the stored root token is valid
  against the restored data.

## Consequences

* Every Cloudron backup contains only crash-consistent artefacts.
* A restore loses writes made after the newest snapshot (up to one hour).
  This is documented, the cadence is visible in the manifest, and a manual
  pre-change snapshot command is documented. A secrets store is a very
  low-write workload; the window is acceptable and, unlike a torn copy, the
  behaviour is deterministic and testable.
* In Shamir mode automatic snapshots stop while sealed and the boot-time
  restore cannot run (no auto-unseal); this is documented as a stated
  trade-off of that mode.
* Changing `persistentDirs` later requires uninstall/reinstall on existing
  installs, so this layout must be right in v1. Greenfield advantage: there
  are no existing installs.

## Rollback

Moving the store back into `/app/data` would be a new major version with a
migration step in `start.sh` (guarded one-time move), and would reintroduce
both hazards. Not planned.
