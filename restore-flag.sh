#!/bin/bash
#
# Cloudron restoreCommand for OpenBao.
#
# The platform runs this in a temporary container after it has put the backup's /app/data back and
# before the app starts, on an in-place restore and on a clone. It does one thing: leave a flag in the
# persistent raft directory saying "a restore happened", so that start.sh replaces the live store with
# the snapshot the backup carries instead of carrying on with it.
#
# Why (field guide #311, measured 2026-10-16 in Batch 7 gate 3): /app/openbao is a persistentDir, and
# an in-place restore leaves it untouched. start.sh only rebuilt from a snapshot when the raft store
# was missing, so every in-place restore since the first release left the live secrets in place: six
# secrets in the backup, eight after the restore. A clone starts empty, which is why earlier gates
# (which used clones) never saw it.
#
# The decision stays in start.sh (step 4b), which knows the seal mode and whether the restored backup
# carries a snapshot. This script only records that a restore happened, because start.sh cannot tell
# an in-place restore from an ordinary restart by itself.
#
# It exits non-zero if the flag cannot be written: a restore that cannot be honoured should fail where
# the operator sees it, not quietly become a restart that rolls nothing back.

set -u
FLAG=/app/openbao/.restore-pending

if ! printf 'restore requested %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${FLAG}"; then
  echo "restore-flag: could not write ${FLAG}; the secrets store would not be rolled back" >&2
  exit 1
fi
exit 0
