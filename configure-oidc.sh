#!/bin/bash
# Idempotent Cloudron SSO wiring for OpenBao, run at every boot when the oidc
# addon is present. Cloudron accounts get a UI login via OpenBao's OIDC auth
# method with the "default" policy only: they exist, they can log in, they can
# read no secrets until an operator attaches policies. Static-seal mode only
# (needs the stored root token); Shamir operators wire OIDC themselves.
#
# Config is re-applied every boot because the addon's client id, secret and
# discovery URL can change across restarts.
set -uo pipefail

DATA=/app/data
ROOT_TOKEN_FILE="${DATA}/.secrets/root-token"
export BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"

log() { echo "==> [oidc] $*"; }

[[ -n "${CLOUDRON_OIDC_DISCOVERY_URL:-}" ]] || { log "oidc addon not present; skipping"; exit 0; }
[[ -f "${ROOT_TOKEN_FILE}" ]] || { log "no stored root token (Shamir mode?); configure OIDC manually"; exit 0; }
[[ -n "${CLOUDRON_APP_ORIGIN:-}" ]] || { log "no app origin; skipping"; exit 0; }

# Wait for the server to be up and unsealed (bounded).
for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${BAO_ADDR}/v1/sys/health?standbyok=true" || true)
    [[ "${code}" == "200" ]] && break
    sleep 2
done
if [[ "${code:-}" != "200" ]]; then
    log "server not available and unsealed; skipping this boot"
    exit 0
fi

BAO_TOKEN="$(cat "${ROOT_TOKEN_FILE}")"
export BAO_TOKEN

# Enable the auth method once; visible on the UI login screen.
if ! bao auth list -format=json 2>/dev/null | jq -e '."oidc/"' > /dev/null; then
    bao auth enable oidc > /dev/null 2>&1 || { log "WARNING: could not enable the oidc auth method"; exit 0; }
    log "enabled oidc auth method"
fi
bao auth tune -listing-visibility=unauth oidc/ > /dev/null 2>&1 || true

# Operator-tunable role settings survive the every-boot rewrite: reuse the
# existing role's policies and TTLs, forcing only the addon-derived fields.
ROLE_POLICIES="default"
ROLE_TTL="8h"
ROLE_MAX_TTL="24h"
existing=$(bao read -format=json auth/oidc/role/cloudron 2>/dev/null || true)
if [[ -n "${existing}" ]]; then
    p=$(jq -r '.data.token_policies // [] | join(",")' <<< "${existing}" 2>/dev/null)
    [[ -n "${p}" ]] && ROLE_POLICIES="${p}"
    t=$(jq -r '.data.token_ttl // empty' <<< "${existing}" 2>/dev/null)
    [[ -n "${t}" ]] && ROLE_TTL="${t}"
    m=$(jq -r '.data.token_max_ttl // empty' <<< "${existing}" 2>/dev/null)
    [[ -n "${m}" ]] && ROLE_MAX_TTL="${m}"
fi

# (Re-)apply provider config and the login role, every boot.
if bao write auth/oidc/config \
        oidc_discovery_url="${CLOUDRON_OIDC_DISCOVERY_URL%/.well-known/openid-configuration}" \
        oidc_client_id="${CLOUDRON_OIDC_CLIENT_ID}" \
        oidc_client_secret="${CLOUDRON_OIDC_CLIENT_SECRET}" \
        default_role="cloudron" > /dev/null 2>&1; then
    bao write auth/oidc/role/cloudron \
        role_type="oidc" \
        user_claim="sub" \
        oidc_scopes="openid,profile,email" \
        bound_audiences="${CLOUDRON_OIDC_CLIENT_ID}" \
        allowed_redirect_uris="${CLOUDRON_APP_ORIGIN}/ui/vault/auth/oidc/oidc/callback" \
        token_policies="${ROLE_POLICIES}" \
        token_ttl="${ROLE_TTL}" \
        token_max_ttl="${ROLE_MAX_TTL}" > /dev/null 2>&1 \
        && log "Cloudron SSO configured (role 'cloudron', policies: ${ROLE_POLICIES})" \
        || log "WARNING: could not write the oidc role"
else
    log "WARNING: could not write the oidc provider config"
fi

unset BAO_TOKEN
exit 0
