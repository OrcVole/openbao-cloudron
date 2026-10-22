#!/bin/bash
set -euo pipefail

# OpenBao for Cloudron entrypoint.
#
# Boot states:
#   first run   store empty, no snapshots -> generate key, init, provision
#   normal      store has data            -> exec the server
#   restore     store empty, snapshots present in /app/data
#               (a Cloudron restore or clone brings back /app/data, but the
#               raft store lives on a persistentDir, which restores empty)
#                                         -> init a scratch cluster, restore
#                                            the newest snapshot into it
#
# First-run and restore work happens on a private listener (127.0.0.1:8299)
# so the public port never serves a half-provisioned or scratch store; every
# path ends by exec-ing the server on the real listener.
#
# Seal modes:
#   static (default)  auto-unseal via a package-generated 32-byte key file
#   shamir (opt-in)   marker file present; operator owns init and unseal

readonly CODE=/app/code
readonly DATA=/app/data
readonly RAFT_ROOT=/app/openbao
readonly RAFT_DIR="${RAFT_ROOT}/data"
readonly CONFIG_DIR="${DATA}/config"
readonly SECRETS_DIR="${DATA}/.secrets"
readonly SNAP_DIR="${DATA}/snapshots"
readonly AUDIT_DIR="${DATA}/audit"
readonly KEY_FILE="${SECRETS_DIR}/unseal.key"
readonly PREV_KEY_FILE="${SECRETS_DIR}/unseal.key.prev"
readonly SHAMIR_MARKER="${SECRETS_DIR}/SHAMIR"
readonly MANAGED_HCL="${CONFIG_DIR}/zz-managed.hcl"
readonly MAIN_HCL="${CONFIG_DIR}/main.hcl"
readonly PUBLIC_ADDR="0.0.0.0:8200"
readonly SCRATCH_ADDR="127.0.0.1:8299"
readonly PLUGIN_DIR="${CODE}/plugins"

ulimit -c 0

echo "==> [start] OpenBao ${OPENBAO_VERSION:-unknown} booting"

# --- 1. Layout and ownership. A restore resets both, so re-assert every boot. ---
mkdir -p "${CONFIG_DIR}" "${SECRETS_DIR}" "${SNAP_DIR}" "${AUDIT_DIR}" "${RAFT_DIR}"
chown -R cloudron:cloudron "${DATA}" "${RAFT_ROOT}"
chmod 0700 "${SECRETS_DIR}" "${SNAP_DIR}"
for f in "${KEY_FILE}" "${PREV_KEY_FILE}" "${SECRETS_DIR}/root-token" \
         "${SECRETS_DIR}/init.json" "${SECRETS_DIR}/snapshot-token"; do
    [[ -f "$f" ]] && { chown cloudron:cloudron "$f"; chmod 0600 "$f"; }
done

# --- 2. Seal mode ---
SEAL_MODE=static
if [[ -f "${SHAMIR_MARKER}" ]]; then
    SEAL_MODE=shamir
elif [[ "${OPENBAO_SEAL:-}" == "shamir" && ! -f "${KEY_FILE}" && ! -e "${RAFT_DIR}/raft/raft.db" ]]; then
    # Operator opted out of auto-unseal before first initialisation.
    touch "${SHAMIR_MARKER}"
    chown cloudron:cloudron "${SHAMIR_MARKER}"
    SEAL_MODE=shamir
fi

if [[ "${SEAL_MODE}" == "static" && ! -f "${KEY_FILE}" ]]; then
    echo "==> [start] first run: generating static unseal key"
    ( umask 077; openssl rand -out "${KEY_FILE}" 32 )
    chown cloudron:cloudron "${KEY_FILE}"; chmod 0600 "${KEY_FILE}"
fi

# --- 3. Managed config (listener, api_addr, seal), regenerated as needed ---
write_managed_config() { # write_managed_config <listen-addr>
    local listen_addr="$1" xff_block="" seal_block=""

    if [[ -n "${CLOUDRON_PROXY_IP:-}" ]]; then
        local proxy_cidr="${CLOUDRON_PROXY_IP}"
        [[ "${proxy_cidr}" != */* ]] && proxy_cidr="${proxy_cidr}/32"
        xff_block=$(printf '  x_forwarded_for_authorized_addrs = "%s"\n  x_forwarded_for_reject_not_present = "false"\n  x_forwarded_for_reject_not_authorized = "false"' "${proxy_cidr}")
    fi

    if [[ "${SEAL_MODE}" == "static" ]]; then
        local key_id prev_id
        key_id="$(sha256sum < "${KEY_FILE}" | cut -c1-8)"
        seal_block=$(printf 'seal "static" {\n  current_key_id = "%s"\n  current_key    = "file://%s"' "${key_id}" "${KEY_FILE}")
        if [[ -f "${PREV_KEY_FILE}" ]]; then
            prev_id="$(sha256sum < "${PREV_KEY_FILE}" | cut -c1-8)"
            seal_block+=$(printf '\n  previous_key_id = "%s"\n  previous_key    = "file://%s"' "${prev_id}" "${PREV_KEY_FILE}")
        fi
        if [[ "${OPENBAO_SEAL_DISABLED:-}" == "true" ]]; then
            seal_block+=$'\n  disabled = "true"'
            echo "==> [start] seal migration mode: static seal marked disabled"
        fi
        seal_block+=$'\n}'
    fi

    # External plugins (the engines OpenBao 2.7 removed from the main binary). Declared here, not in
    # main.hcl, so existing installs get them. A binary that is not on disk is left out, because a
    # missing binary named here would abort unseal. OPENBAO_NO_PLUGINS=true omits the block (test hook).
    local plugin_block=""
    if [[ "${OPENBAO_NO_PLUGINS:-}" != "true" ]]; then
        local ptype pname bin sum
        while read -r ptype pname bin sum; do
            [[ -f "${PLUGIN_DIR}/${bin}" ]] || continue
            plugin_block+=$(printf 'plugin "%s" "%s" {\n  command   = "%s"\n  version   = "%s"\n  sha256sum = "%s"\n}\n' \
                "${ptype}" "${pname}" "${bin}" "${PLUGINS_VERSION}" "${sum}")$'\n'
        done <<PLUGINS
auth ldap openbao-plugin-auth-ldap_linux_amd64_v1 ${PLUGIN_AUTH_LDAP_BIN_SHA256:-}
auth radius openbao-plugin-auth-radius_linux_amd64_v1 ${PLUGIN_AUTH_RADIUS_BIN_SHA256:-}
auth kerberos openbao-plugin-auth-kerberos_linux_amd64_v1 ${PLUGIN_AUTH_KERBEROS_BIN_SHA256:-}
secret ldap openbao-plugin-secrets-ldap_linux_amd64_v1 ${PLUGIN_SECRETS_LDAP_BIN_SHA256:-}
PLUGINS
        if [[ -n "${plugin_block}" ]]; then
            # plugin_auto_register is stated explicitly on purpose: its default (true) is lost when the
            # server merges the files of a config directory (measured on 2.7.1, gate 3), so without
            # this line the stanzas below are parsed and then silently never registered.
            plugin_block="plugin_directory = \"${PLUGIN_DIR}\"
plugin_auto_register = true
${plugin_block}"
        fi
    fi

    cat > "${MANAGED_HCL}" <<EOF
# Managed by the Cloudron package. Regenerated on every start; do not edit.
# Operator settings belong in main.hcl.
listener "tcp" {
  address     = "${listen_addr}"
  tls_disable = "true"
${xff_block}
}
api_addr = "${CLOUDRON_APP_ORIGIN:-http://127.0.0.1:8200}"
${seal_block}
${plugin_block}
EOF
    chown cloudron:cloudron "${MANAGED_HCL}"
}

# --- 4. Operator config, generated once ---
if [[ ! -f "${MAIN_HCL}" ]]; then
    cat > "${MAIN_HCL}" <<'EOF'
# OpenBao operator configuration. Generated once at first start; your edits
# survive restarts, updates and restores. The listener, seal and api_addr are
# package-managed in zz-managed.hcl; do not redefine them here.
ui = true

storage "raft" {
  path    = "/app/openbao/data"
  node_id = "openbao-cloudron"
}

cluster_addr = "http://127.0.0.1:8201"

# File audit log (OpenBao manages audit devices declaratively; the API route
# is disabled upstream). Remove this block and restart to disable auditing.
# The package rotates the file at 64 MB.
audit "file" "default" {
  options {
    file_path = "/app/data/audit/audit.log"
  }
}
EOF
    chown cloudron:cloudron "${MAIN_HCL}"
fi

# --- helpers for the scratch (private listener) phases ---
SERVER_PID=""

start_scratch_server() {
    write_managed_config "${SCRATCH_ADDR}"
    gosu cloudron:cloudron "${CODE}/bao" server -config "${CONFIG_DIR}" &
    SERVER_PID=$!
    trap 'kill -TERM "${SERVER_PID}" 2>/dev/null || true; exit 143' TERM INT
    export BAO_ADDR="http://${SCRATCH_ADDR}"
}

stop_scratch_server() {
    trap - TERM INT
    kill -TERM "${SERVER_PID}" 2>/dev/null || true
    local i
    for i in $(seq 1 30); do
        kill -0 "${SERVER_PID}" 2>/dev/null || break
        sleep 1
    done
    kill -9 "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""
}

wait_scratch() { # wait_scratch <extra-params> <tries>
    local i
    for i in $(seq 1 "${2:-90}"); do
        if curl -sf -o /dev/null --max-time 2 "http://${SCRATCH_ADDR}/v1/sys/health?${1}"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

secure_secret_file() {
    chown cloudron:cloudron "$1"; chmod 0600 "$1"
}

exec_server() {
    write_managed_config "${PUBLIC_ADDR}"
    # Address the backupCommand's temporary container (cloudron network, no
    # CLOUDRON_* env, no localhost server) can reach the live server on.
    CONTAINER_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)"
    if [[ -n "${CONTAINER_IP}" ]]; then
        printf 'http://%s:8200\n' "${CONTAINER_IP}" > "${DATA}/.snapshot-endpoint"
        chown cloudron:cloudron "${DATA}/.snapshot-endpoint"
    fi
    # Cloudron SSO wiring runs against the live server after it is up; it is
    # forked before exec and survives as an orphan of the server process. The
    # BAO_ADDR override matters: the first-run path exports the scratch
    # listener's address, which is dead by now.
    ( sleep 2; BAO_ADDR="http://127.0.0.1:8200" /app/code/configure-oidc.sh ) &
    # Carry mounts that predate OpenBao 2.7 (LDAP, RADIUS, Kerberos) over to the bundled plugins (ADR 0007).
    ( BAO_ADDR="http://127.0.0.1:8200" /app/code/migrate-plugins.sh ) &
    echo "==> [start] http on ${PUBLIC_ADDR}"
    exec gosu cloudron:cloudron "${CODE}/bao" server -config "${CONFIG_DIR}"
}

# --- 4b. A Cloudron restore happened (restore-flag.sh left the flag) ---
# /app/openbao is a persistentDir, so an in-place restore leaves the live store in place, and without
# this the restore rolled nothing back (field guide #311; Batch 7 gate 3, 2026-10-16). Move the live
# store aside, never delete it, so the restore path below rebuilds from the snapshot the backup carries.
readonly RESTORE_FLAG="${RAFT_ROOT}/.restore-pending"
if [[ -f "${RESTORE_FLAG}" ]]; then
    rm -f "${RESTORE_FLAG}"
    if [[ ! -e "${RAFT_DIR}/raft/raft.db" && ! -e "${RAFT_DIR}/vault.db" ]]; then
        echo "==> [start] restore: the raft store is empty (a clone); restoring from the backup's snapshot"
    elif [[ "${SEAL_MODE}" == "shamir" ]]; then
        echo "==> [start] RESTORE NOT APPLIED: a backup was restored, but with the Shamir seal the store"
        echo "==> [start] cannot be rebuilt automatically. The LIVE store is still in use, not the backup's."
        echo "==> [start] See the package README for the manual restore procedure."
    elif ! compgen -G "${SNAP_DIR}/*.snap" > /dev/null; then
        echo "==> [start] RESTORE NOT APPLIED: the restored backup carries no snapshot in ${SNAP_DIR}."
        echo "==> [start] The LIVE store is still in use, not the backup's."
    else
        quarantine="${RAFT_ROOT}/quarantine-$(date -u +%Y%m%dT%H%M%SZ)"
        mv "${RAFT_DIR}" "${quarantine}"
        mkdir -p "${RAFT_DIR}"
        chown cloudron:cloudron "${RAFT_DIR}"
        echo "==> [start] restore: a backup was restored over this app; the live store was moved to"
        echo "==> [start] ${quarantine} (kept 30 days) and the store is rebuilt from the backup's snapshot"
    fi
fi
# Quarantined stores older than 30 days are removed.
find "${RAFT_ROOT}" -mindepth 1 -maxdepth 1 -type d -name 'quarantine-*' -mtime +30 -exec rm -rf {} + 2>/dev/null || true

# --- 5. Choose the boot path ---
if [[ -e "${RAFT_DIR}/raft/raft.db" || -e "${RAFT_DIR}/vault.db" ]]; then
    BOOT_PATH=normal
elif compgen -G "${SNAP_DIR}/*.snap" > /dev/null; then
    BOOT_PATH=restore
else
    BOOT_PATH=first-run
fi
echo "==> [start] seal mode: ${SEAL_MODE}, boot path: ${BOOT_PATH}"
# Machine-readable breadcrumbs for this boot (tmpfs, so always current-boot).
printf '%s\n' "${BOOT_PATH}" > /run/openbao-boot-path
printf '%s\n' "${SEAL_MODE}" > /run/openbao-seal-mode

if [[ "${SEAL_MODE}" == "shamir" ]]; then
    if [[ "${BOOT_PATH}" == "restore" ]]; then
        echo "==> [start] NOTE: snapshots exist but the raft store is empty."
        echo "==> [start] Automatic restore is not possible with the Shamir seal."
        echo "==> [start] See the package README for the manual restore procedure."
    elif [[ "${BOOT_PATH}" == "first-run" ]]; then
        echo "==> [start] Shamir mode: initialise and unseal via the web UI."
    fi
    exec_server
fi

# --- static seal paths ---
case "${BOOT_PATH}" in

normal)
    echo "==> [start] existing store found, auto-unseal via static key"
    exec_server
    ;;

first-run)
    echo "==> [start] first run: initialising OpenBao (private listener)"
    # On any failure before credentials are safely stored, wipe the scratch
    # store so the next boot retries first-run instead of silently taking the
    # normal path with an unusable half-provisioned store.
    abort_first_run() {
        echo "==> [start] ERROR: $1; wiping scratch store so next start retries" >&2
        stop_scratch_server
        rm -rf "${RAFT_DIR:?}" && mkdir -p "${RAFT_DIR}" && chown cloudron:cloudron "${RAFT_DIR}"
        exit 1
    }
    start_scratch_server
    wait_scratch "uninitcode=200&sealedcode=200&standbycode=200" || abort_first_run "server did not start listening"

    INIT_JSON=/run/openbao-init.json
    ( umask 077; "${CODE}/bao" operator init -recovery-shares=5 -recovery-threshold=3 -format=json > "${INIT_JSON}" ) \
        || abort_first_run "operator init failed"
    wait_scratch "standbyok=true" 60 || abort_first_run "server did not unseal after init"

    ROOT_TOKEN="$(jq -r .root_token "${INIT_JSON}")"
    [[ -n "${ROOT_TOKEN}" && "${ROOT_TOKEN}" != "null" ]] || abort_first_run "init produced no root token"

    ( umask 077
      printf '%s\n' "${ROOT_TOKEN}" > "${SECRETS_DIR}/root-token"
      cp "${INIT_JSON}" "${SECRETS_DIR}/init.json"
    )
    secure_secret_file "${SECRETS_DIR}/root-token"
    secure_secret_file "${SECRETS_DIR}/init.json"
    rm -f "${INIT_JSON}"

    export BAO_TOKEN="${ROOT_TOKEN}"

    # Credentials are safe on disk from here; provisioning failures below are
    # warnings, not crash loops (the operator can complete them by hand).
    # The file audit device is declarative, in main.hcl; the API route is
    # disabled upstream.
    echo "==> [start] enabling KV v2 at secret/ and snapshot access"
    "${CODE}/bao" secrets enable -path=secret -version=2 kv \
        || echo "==> [start] WARNING: could not mount KV v2 at secret/" >&2
    if printf 'path "sys/storage/raft/snapshot" {\n  capabilities = ["read"]\n}\n' \
        | "${CODE}/bao" policy write snapshot-backup -; then
        ( umask 077
          "${CODE}/bao" token create -orphan -policy=snapshot-backup -period=768h \
              -display-name=cloudron-snapshot -format=json \
              | jq -r .auth.client_token > "${SECRETS_DIR}/snapshot-token"
        ) && secure_secret_file "${SECRETS_DIR}/snapshot-token" \
          || echo "==> [start] WARNING: could not create the snapshot token" >&2
    else
        echo "==> [start] WARNING: could not write the snapshot policy" >&2
    fi
    unset BAO_TOKEN ROOT_TOKEN

    cat > "${SECRETS_DIR}/README.txt" <<'EOF'
Credentials for this OpenBao instance. Every file here is 0600, cloudron:cloudron.

  root-token      the initial root token. Log in with it, create your own admin
                  auth (userpass, OIDC), then consider revoking it.
  init.json       full output of "bao operator init": the recovery key shares
                  (needed for seal migration or recovery operations) and the
                  root token. Copy it somewhere OUTSIDE this server, then you
                  may delete it here.
  unseal.key      the static auto-unseal key (raw 32 bytes). Losing it makes
                  the store unreadable; keep an off-server copy.
  snapshot-token  limited token the hourly snapshot job uses. Not for humans.
EOF
    chown cloudron:cloudron "${SECRETS_DIR}/README.txt"

    BAO_ADDR="http://${SCRATCH_ADDR}" "${CODE}/snapshot.sh" first-boot \
        || echo "==> [start] WARNING: first snapshot failed (will retry hourly)"

    stop_scratch_server
    echo "==> [start] initialised; credentials in ${SECRETS_DIR} (see README.txt there)"
    exec_server
    ;;

restore)
    LATEST_SNAP="$(ls -1t "${SNAP_DIR}"/*.snap 2>/dev/null | head -n1)"
    echo "==> [start] empty store with snapshot present: restoring ${LATEST_SNAP##*/} (private listener)"
    # On failure, wipe the scratch cluster so the next boot retries the restore
    # instead of serving an empty store that looks healthy.
    abort_restore() {
        echo "==> [start] ERROR: $1" >&2
        echo "==> [start] If the unseal key was rotated after this snapshot was taken," >&2
        echo "==> [start] place the matching key at ${KEY_FILE} and restart." >&2
        stop_scratch_server
        rm -rf "${RAFT_DIR:?}" && mkdir -p "${RAFT_DIR}" && chown cloudron:cloudron "${RAFT_DIR}"
        exit 1
    }
    start_scratch_server
    wait_scratch "uninitcode=200&sealedcode=200&standbycode=200" || abort_restore "server did not start listening"

    TMP_INIT=/run/openbao-tmp-init.json
    ( umask 077; "${CODE}/bao" operator init -recovery-shares=1 -recovery-threshold=1 -format=json > "${TMP_INIT}" ) \
        || abort_restore "scratch init failed"
    wait_scratch "standbyok=true" 60 || abort_restore "scratch cluster did not unseal"

    TMP_TOKEN="$(jq -r .root_token "${TMP_INIT}")"
    rm -f "${TMP_INIT}"

    BAO_TOKEN="${TMP_TOKEN}" "${CODE}/bao" operator raft snapshot restore -force "${LATEST_SNAP}" \
        || abort_restore "snapshot restore command failed"
    unset TMP_TOKEN

    wait_scratch "standbyok=true" 90 || abort_restore "server not healthy after snapshot restore"

    if [[ -f "${SECRETS_DIR}/root-token" ]]; then
        if BAO_TOKEN="$(cat "${SECRETS_DIR}/root-token")" "${CODE}/bao" token lookup > /dev/null 2>&1; then
            echo "==> [start] restore verified: stored root token is valid against the restored data"
            printf 'verified\n' > /run/openbao-restore-status
        else
            echo "==> [start] WARNING: stored root token is not valid against the restored data" >&2
            printf 'token-invalid\n' > /run/openbao-restore-status
        fi
    else
        printf 'no-stored-token\n' > /run/openbao-restore-status
    fi

    stop_scratch_server
    echo "==> [start] restore complete"
    exec_server
    ;;
esac
