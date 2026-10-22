#!/bin/bash
# One-time carry-over of mounts that predate OpenBao 2.7 (ADR 0007).
#
# Until 2.6.x the LDAP, RADIUS and Kerberos auth engines and the LDAP secrets engine were built into
# the server, so a mount of one of them carries no plugin version. From 2.7 they are external plugins
# (bundled in /app/code/plugins and registered in zz-managed.hcl, at a version), and a mount with no
# version can no longer find its engine: it stays listed but every request fails. Tuning the mount to
# the bundled plugin version fixes it, keeps its configuration, users, policies and entity ids, and
# survives restarts. This script does exactly that, once per such mount, and does nothing otherwise.
#
# Credentials: it reads the mount lists with the stored root token, then mints a five-minute orphan
# token whose policy allows only "tune" on the mounts that need it plus the plugin reload call, uses
# that, and revokes it. No token or policy outlives the run, and no value is printed.
#
# Runs in the background after the server starts (exec_server). It waits for an active, unsealed
# server (a Shamir install is unsealed by its operator, possibly much later).
set -uo pipefail

readonly SECRETS_DIR=/app/data/.secrets
readonly ROOT_TOKEN_FILE="${SECRETS_DIR}/root-token"
readonly BAO=/app/code/bao
readonly VERSION="${PLUGINS_VERSION:-}"
export BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
log() { echo "==> [plugins] $*"; }

[[ "${OPENBAO_NO_PLUGINS:-}" == "true" || -z "${VERSION}" ]] && exit 0
[[ -d /app/code/plugins ]] || exit 0

# Wait for an active node (health 200). Poll for up to an hour: a sealed Shamir install waits for its operator.
ready=""
for _ in $(seq 1 720); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${BAO_ADDR}/v1/sys/health")" == "200" ]] && { ready=1; break; }
    sleep 5
done
[[ -n "${ready}" ]] || { log "server did not become active; carry-over of pre-2.7 mounts not attempted"; exit 0; }

if [[ ! -s "${ROOT_TOKEN_FILE}" ]]; then
    log "no stored root token; pre-2.7 LDAP, RADIUS or Kerberos mounts (if any) are not carried over automatically, see the README"
    exit 0
fi
ROOT="$(cat "${ROOT_TOKEN_FILE}")"

# Mounts of the four engines that report no plugin version: "<kind> <path>" per line (kind: auth|secrets).
need="$(
    {
        BAO_TOKEN="${ROOT}" "${BAO}" read -format=json sys/auth 2>/dev/null \
            | jq -r '.data // {} | to_entries[] | select(.value.type=="ldap" or .value.type=="radius" or .value.type=="kerberos")
                     | select((.value.plugin_version // "")=="") | "auth \(.key)"'
        BAO_TOKEN="${ROOT}" "${BAO}" read -format=json sys/mounts 2>/dev/null \
            | jq -r '.data // {} | to_entries[] | select(.value.type=="ldap")
                     | select((.value.plugin_version // "")=="") | "secrets \(.key)"'
    } | grep -E '^(auth|secrets) [A-Za-z0-9_./-]+/$' || true
)"
if [[ -z "${need}" ]]; then
    unset ROOT
    exit 0
fi

log "carrying pre-2.7 mounts over to plugin ${VERSION}:" $(echo "${need}" | tr '\n' ' ')

policy='path "sys/plugins/reload/backend" {
  capabilities = ["update"]
}
'
while read -r kind mpath; do
    [[ -n "${kind}" ]] || continue
    # "bao auth tune" posts to sys/mounts/auth/<path>/tune; sys/auth/<path>/tune is the same operation.
    if [[ "${kind}" == "auth" ]]; then tunepaths=("sys/mounts/auth/${mpath}tune" "sys/auth/${mpath}tune"); else tunepaths=("sys/mounts/${mpath}tune"); fi
    for tp in "${tunepaths[@]}"; do
        policy+="path \"${tp}\" {
  capabilities = [\"update\"]
}
"
    done
done <<< "${need}"

BAO_TOKEN="${ROOT}" "${BAO}" policy write plugin-migrate - <<< "${policy}" > /dev/null \
    || { log "WARNING: could not write the carry-over policy; mounts not carried over"; unset ROOT; exit 0; }
TOKEN="$(BAO_TOKEN="${ROOT}" "${BAO}" token create -orphan -policy=plugin-migrate -ttl=5m -renewable=false \
            -display-name=plugin-migrate -format=json 2>/dev/null | jq -r '.auth.client_token // empty')"
if [[ -z "${TOKEN}" ]]; then
    log "WARNING: could not mint the carry-over token; mounts not carried over"
    BAO_TOKEN="${ROOT}" "${BAO}" policy delete plugin-migrate > /dev/null 2>&1
    unset ROOT; exit 0
fi

while read -r kind mpath; do
    [[ -n "${kind}" ]] || continue
    if BAO_TOKEN="${TOKEN}" "${BAO}" "${kind}" tune "-plugin-version=${VERSION}" "${mpath}" > /dev/null 2>&1; then
        reloadpath="${mpath}"; [[ "${kind}" == "auth" ]] && reloadpath="auth/${mpath}"
        if BAO_TOKEN="${TOKEN}" "${BAO}" plugin reload "-mounts=${reloadpath}" > /dev/null 2>&1; then
            log "${kind} mount ${mpath} now runs plugin ${VERSION}"
        else
            log "WARNING: ${kind} mount ${mpath} tuned but not reloaded; restart the app to load it"
        fi
    else
        log "WARNING: could not tune ${kind} mount ${mpath} to plugin ${VERSION}; run: bao ${kind} tune -plugin-version=${VERSION} ${mpath}"
    fi
done <<< "${need}"

# Nothing of this run outlives it.
BAO_TOKEN="${TOKEN}" "${BAO}" token revoke -self > /dev/null 2>&1 || true
BAO_TOKEN="${ROOT}" "${BAO}" policy delete plugin-migrate > /dev/null 2>&1 || true
unset ROOT TOKEN
exit 0
