#!/bin/bash
# Runtime smoke test for the OpenBao Cloudron package.
#
# Runs the built image the way Cloudron does (read-only rootfs, tmpfs /run and
# /tmp, volumes for /app/data and /app/openbao, root entrypoint) and asserts
# real behaviour: auto-init, health semantics in all three states, restart
# auto-unseal, snapshot save, restore-into-fresh-store, key rotation, secret
# hygiene. Requires: podman, curl, jq.
#
# Usage: test/smoke.sh <image-ref>
set -uo pipefail

IMAGE="${1:?usage: smoke.sh <image-ref>}"
P=openbao-smoke-$$
PORT=18200
SHAMIR_PORT=18201
FAILS=0
PASS_COUNT=0

say()  { echo "[smoke] $*"; }
pass() { PASS_COUNT=$((PASS_COUNT+1)); say "PASS: $*"; }
fail() { FAILS=$((FAILS+1)); say "FAIL: $*"; }

cleanup() {
    podman rm -f "${P}-main" "${P}-shamir" "${P}-restore" > /dev/null 2>&1
    podman volume rm -f "${P}-data" "${P}-raft" "${P}-raft2" "${P}-sdata" "${P}-sraft" > /dev/null 2>&1
}
trap cleanup EXIT

health() { # health <port> [params] -> prints http code
    curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$1/v1/sys/health${2:+?$2}" || echo 000
}

wait_code() { # wait_code <port> <params> <code> <tries>
    local i; for i in $(seq 1 "${4:-60}"); do
        [[ "$(health "$1" "$2")" == "$3" ]] && return 0
        sleep 1
    done
    return 1
}

crun() { podman exec "${P}-main" "$@"; }

MANIFEST_PARAMS='standbyok=true&uninitcode=200&sealedcode=503'

say "=== 1. main container: first boot, auto-init ==="
podman volume create "${P}-data" > /dev/null
podman volume create "${P}-raft" > /dev/null
podman run -d --name "${P}-main" --read-only --tmpfs /run --tmpfs /tmp \
    -v "${P}-data":/app/data -v "${P}-raft":/app/openbao \
    -e CLOUDRON_APP_ORIGIN="http://127.0.0.1:${PORT}" \
    -p "127.0.0.1:${PORT}:8200" "${IMAGE}" > /dev/null || { fail "container start"; exit 1; }

if wait_code "${PORT}" "" 200 90; then pass "auto-init reached active (bare health 200)"; else
    fail "auto-init did not reach active"; podman logs --tail 40 "${P}-main"; exit 1; fi

for f in root-token init.json unseal.key snapshot-token; do
    mode=$(crun stat -c '%a %U' "/app/data/.secrets/$f" 2>/dev/null || echo missing)
    [[ "$mode" == "600 cloudron" ]] && pass ".secrets/$f is 0600 cloudron" || fail ".secrets/$f expected '600 cloudron', got '$mode'"
done

BAO_USER=$(crun ps -o user= -C bao | head -1 | tr -d ' ')
[[ "$BAO_USER" == "cloudron" ]] && pass "bao runs as cloudron" || fail "bao runs as '$BAO_USER'"

crun test -e /app/openbao/data/raft.db && pass "raft store on persistentDir path" || fail "raft.db not found on /app/openbao/data"

[[ "$(health "${PORT}" "${MANIFEST_PARAMS}")" == "200" ]] && pass "manifest health path 200 when active" || fail "manifest health path not 200 when active"

say "=== 2. write data, snapshot, restart auto-unseal ==="
crun bash -c 'export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$(cat /app/data/.secrets/root-token); bao kv put secret/smoke canary=expected-value-42 >/dev/null' \
    && pass "KV write via root token" || fail "KV write failed"

crun /app/code/snapshot.sh > /dev/null 2>&1
SNAPS=$(crun bash -c 'ls -1 /app/data/snapshots/raft-*.snap 2>/dev/null | wc -l')
[[ "${SNAPS}" -ge 1 ]] && pass "snapshot job produced ${SNAPS} snapshot(s)" || fail "no snapshots present after snapshot.sh"

podman restart "${P}-main" > /dev/null
if wait_code "${PORT}" "" 200 60; then pass "restart: auto-unsealed with no intervention"; else fail "restart: did not come back unsealed"; fi
VAL=$(crun bash -c 'export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$(cat /app/data/.secrets/root-token); bao kv get -field=canary secret/smoke' 2>/dev/null)
[[ "$VAL" == "expected-value-42" ]] && pass "KV read-back after restart" || fail "KV read-back after restart got '$VAL'"

say "=== 3. health matrix on a Shamir container (uninit and sealed states) ==="
podman volume create "${P}-sdata" > /dev/null; podman volume create "${P}-sraft" > /dev/null
podman run -d --name "${P}-shamir" --read-only --tmpfs /run --tmpfs /tmp \
    -v "${P}-sdata":/app/data -v "${P}-sraft":/app/openbao \
    -e OPENBAO_SEAL=shamir -p "127.0.0.1:${SHAMIR_PORT}:8200" "${IMAGE}" > /dev/null

if wait_code "${SHAMIR_PORT}" "uninitcode=204" 204 60; then say "shamir container listening"; else fail "shamir container did not listen"; fi
[[ "$(health "${SHAMIR_PORT}")" == "501" ]] && pass "uninitialised: bare health 501" || fail "uninitialised bare health: got $(health "${SHAMIR_PORT}")"
[[ "$(health "${SHAMIR_PORT}" "${MANIFEST_PARAMS}")" == "200" ]] && pass "uninitialised: manifest path 200" || fail "uninitialised manifest path: got $(health "${SHAMIR_PORT}" "${MANIFEST_PARAMS}")"

INIT_JSON=$(curl -s --max-time 5 -X PUT "http://127.0.0.1:${SHAMIR_PORT}/v1/sys/init" -d '{"secret_shares":1,"secret_threshold":1}')
UNSEAL_KEY=$(jq -r '.keys_b64[0]' <<< "${INIT_JSON}")
if [[ -n "${UNSEAL_KEY}" && "${UNSEAL_KEY}" != "null" ]]; then
    say "shamir container initialised (throwaway instance)"
    [[ "$(health "${SHAMIR_PORT}")" == "503" ]] && pass "sealed: bare health 503" || fail "sealed bare health: got $(health "${SHAMIR_PORT}")"
    [[ "$(health "${SHAMIR_PORT}" "${MANIFEST_PARAMS}")" == "503" ]] && pass "sealed: manifest path 503 (the whole point)" || fail "sealed manifest path: got $(health "${SHAMIR_PORT}" "${MANIFEST_PARAMS}")"
    curl -s -o /dev/null --max-time 5 -X PUT "http://127.0.0.1:${SHAMIR_PORT}/v1/sys/unseal" -d "{\"key\":\"${UNSEAL_KEY}\"}"
    sleep 1
    [[ "$(health "${SHAMIR_PORT}")" == "200" ]] && pass "unsealed shamir: bare health 200" || fail "unsealed shamir health: got $(health "${SHAMIR_PORT}")"
else
    fail "shamir init via API failed"
fi
UNSEAL_KEY=""

say "=== 4. restore into a fresh raft store from snapshots ==="
podman stop "${P}-main" > /dev/null
podman volume create "${P}-raft2" > /dev/null
podman run -d --name "${P}-restore" --read-only --tmpfs /run --tmpfs /tmp \
    -v "${P}-data":/app/data -v "${P}-raft2":/app/openbao \
    -e CLOUDRON_APP_ORIGIN="http://127.0.0.1:${PORT}" \
    -p "127.0.0.1:${PORT}:8200" "${IMAGE}" > /dev/null

if wait_code "${PORT}" "" 200 90; then pass "restore boot reached active"; else
    fail "restore boot did not reach active"; podman logs --tail 40 "${P}-restore"; fi
podman logs "${P}-restore" 2>&1 | grep -q "restore verified" && pass "stored root token valid against restored data" || fail "restore verification line missing"
VAL=$(podman exec "${P}-restore" bash -c 'export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$(cat /app/data/.secrets/root-token); bao kv get -field=canary secret/smoke' 2>/dev/null)
[[ "$VAL" == "expected-value-42" ]] && pass "KV data survived snapshot restore" || fail "KV after restore got '$VAL'"

say "=== 5. key rotation ==="
podman exec "${P}-restore" bash -c 'cd /app/data/.secrets && mv unseal.key unseal.key.prev && openssl rand -out unseal.key 32 && chmod 600 unseal.key && chown cloudron:cloudron unseal.key'
podman restart "${P}-restore" > /dev/null
if wait_code "${PORT}" "" 200 60; then pass "rotation: restarted and auto-unsealed under new key"; else fail "rotation: did not come back"; fi
VAL=$(podman exec "${P}-restore" bash -c 'export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$(cat /app/data/.secrets/root-token); bao kv get -field=canary secret/smoke' 2>/dev/null)
[[ "$VAL" == "expected-value-42" ]] && pass "KV readable after key rotation" || fail "KV after rotation got '$VAL'"

say "=== 6. hygiene ==="
ROOT_TOKEN_VAL=$(podman exec "${P}-restore" cat /app/data/.secrets/root-token 2>/dev/null || true)
if [[ -n "${ROOT_TOKEN_VAL}" ]]; then
    if podman logs "${P}-restore" 2>&1 | grep -qF "${ROOT_TOKEN_VAL}"; then fail "root token appears in container logs"; else pass "root token absent from logs"; fi
    if podman logs "${P}-main" 2>&1 | grep -qF "${ROOT_TOKEN_VAL}"; then fail "root token appears in first-boot logs"; else pass "root token absent from first-boot logs"; fi
fi
ROOT_TOKEN_VAL=""

SIZE=$(podman image inspect --format '{{.Size}}' "${IMAGE}" 2>/dev/null || echo 0)
say "image size: $((SIZE / 1024 / 1024)) MiB"

echo
say "=== result: ${PASS_COUNT} passed, ${FAILS} failed ==="
exit $(( FAILS > 0 ? 1 : 0 ))
