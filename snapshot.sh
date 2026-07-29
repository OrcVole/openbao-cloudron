#!/bin/bash
# Raft snapshot job for the OpenBao Cloudron package.
#
# Modes:
#   (no argument)  hourly scheduler task, runs inside the live app container.
#                  Takes a consistent raft snapshot into /app/data/snapshots,
#                  prunes old ones, and rotates the audit log when large.
#   pre-backup     manifest backupCommand. Runs in a TEMPORARY container during
#                  a Cloudron backup, where the live server is not on localhost;
#                  it tries the public origin instead. Best effort: it must
#                  never fail the backup, so every path exits 0.
#   first-boot     called by start.sh right after initialisation.
#
# The snapshot, not the raft directory, is the restore artefact: the raft store
# sits on a persistentDir which is excluded from Cloudron backups by design.
set -uo pipefail

MODE="${1:-scheduled}"
DATA=/app/data
SNAP_DIR="${DATA}/snapshots"
SECRETS_DIR="${DATA}/.secrets"
TOKEN_FILE="${SECRETS_DIR}/snapshot-token"
AUDIT_LOG="${DATA}/audit/audit.log"
KEEP=24
AUDIT_ROTATE_BYTES=$((64 * 1024 * 1024))

log() { echo "==> [snapshot] $*"; }

# Default to the local listener, but respect a caller-provided BAO_ADDR
# (start.sh calls first-boot mode against the private scratch listener).
export BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
if [[ "${MODE}" == "pre-backup" ]]; then
    # Temporary container: no server on localhost. The public origin may or may
    # not be reachable from here; if it is not, the newest hourly snapshot
    # already in /app/data rides the backup instead.
    export BAO_ADDR="${CLOUDRON_APP_ORIGIN:-http://127.0.0.1:8200}"
fi

if [[ ! -f "${TOKEN_FILE}" ]]; then
    log "no snapshot token (Shamir mode or not initialised); nothing to do"
    exit 0
fi

umask 077
mkdir -p "${SNAP_DIR}"
chmod 0700 "${SNAP_DIR}" 2>/dev/null || true

health="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "${BAO_ADDR}/v1/sys/health?standbyok=true" || true)"
if [[ "${health}" != "200" ]]; then
    log "server not available and unsealed (health=${health:-none}) at ${BAO_ADDR}; skipping"
    exit 0
fi

BAO_TOKEN="$(cat "${TOKEN_FILE}")"
export BAO_TOKEN

# Keep the periodic token alive; harmless if it fails this round. JSON output
# to the bit bucket so the token value never reaches the logs.
bao token renew -format=json > /dev/null 2>&1 || log "token renew failed (will still try the snapshot)"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
TMP="${SNAP_DIR}/.tmp-${STAMP}.snap"
FINAL="${SNAP_DIR}/raft-${STAMP}.snap"

if bao operator raft snapshot save "${TMP}" > /dev/null 2>&1; then
    mv -f "${TMP}" "${FINAL}"
    ln -sfn "${FINAL##*/}" "${SNAP_DIR}/latest.snap"
    log "saved ${FINAL##*/} ($(stat -c %s "${FINAL}") bytes)"
else
    rm -f "${TMP}"
    log "snapshot save FAILED against ${BAO_ADDR}"
    [[ "${MODE}" == "pre-backup" ]] && exit 0
    exit 0
fi

# Prune: keep the newest ${KEEP} snapshots.
mapfile -t old < <(ls -1t "${SNAP_DIR}"/raft-*.snap 2>/dev/null | tail -n +$((KEEP + 1)))
if (( ${#old[@]} > 0 )); then
    rm -f "${old[@]}"
    log "pruned ${#old[@]} old snapshot(s)"
fi

# Audit log rotation (scheduled mode only; the server can reopen its file on
# SIGHUP). One rotated generation is kept.
if [[ "${MODE}" != "pre-backup" && -f "${AUDIT_LOG}" ]]; then
    size="$(stat -c %s "${AUDIT_LOG}" 2>/dev/null || echo 0)"
    if (( size > AUDIT_ROTATE_BYTES )); then
        mv -f "${AUDIT_LOG}" "${AUDIT_LOG}.1"
        if pkill -HUP -x -o bao 2>/dev/null; then
            log "rotated audit log (${size} bytes) and sent SIGHUP"
        else
            log "rotated audit log but could not signal the server"
        fi
    fi
fi

exit 0
