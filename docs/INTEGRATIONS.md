# Wiring other Cloudron apps to OpenBao

OpenBao's API is Vault-compatible and served on the app's public origin, so
any application, on the same Cloudron or elsewhere, can use it as its secrets
backend with stock Vault client libraries. Containers on the same Cloudron
can reach the public origin directly (the hairpin resolves; no split-horizon
tricks needed, verified on Cloudron 9.2).

## Cloudron single sign-on (for humans)

When installed with Cloudron user management, the package wires the `oidc`
addon into OpenBao's OIDC auth method automatically. Cloudron users pick
"OIDC" on the OpenBao login screen and sign in with their Cloudron account.

They arrive with the `default` policy only: they exist, they can log in, and
they can read nothing. Granting access is a deliberate operator act:

```
# in the app's Web Terminal, authenticated as an admin
bao policy write readers - <<'EOF'
path "secret/data/shared/*" { capabilities = ["read", "list"] }
EOF
bao write auth/oidc/role/cloudron token_policies="default,readers"
```

(That grants every Cloudron user `readers`; for per-user or per-group grants
use identity entities and groups, see the OpenBao identity documentation.)

Grants persist: the package re-applies the OIDC wiring on every boot (the
addon's client credentials can change), but it preserves the role's
`token_policies`, `token_ttl` and `token_max_ttl`, so policies you attach and
TTLs you tune survive restarts and updates.

SSO here is the UI login only. The CLI's own OIDC flow needs a localhost
redirect that cannot be registered with Cloudron's provider; CLI and machine
access use tokens, userpass or AppRole as below.

## AppRole for machines (the recommended pattern)

Give each consuming application its own AppRole bound to a minimal policy:

```
# one-time, as an admin, in the app's Web Terminal
bao auth enable approle 2>/dev/null || true
bao policy write myapp - <<'EOF'
path "secret/data/myapp/*" { capabilities = ["read"] }
EOF
bao write auth/approle/role/myapp \
    token_policies="myapp" token_ttl=1h token_max_ttl=4h
bao read -field=role_id auth/approle/role/myapp/role-id
bao write -f -field=secret_id auth/approle/role/myapp/secret-id
```

Hand the two values to the consuming app (its own env vars or config), never
the root token. The consumer logs in and reads:

```bash
BAO_ADDR=https://bao.example.com
TOKEN=$(curl -s -X POST "$BAO_ADDR/v1/auth/approle/login" \
    -d "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"$SECRET_ID\"}" \
    | jq -r .auth.client_token)
curl -s -H "X-Vault-Token: $TOKEN" \
    "$BAO_ADDR/v1/secret/data/myapp/database" | jq -r .data.data.password
```

Vault SDKs (Go, Python `hvac`, Node `node-vault`, Terraform's Vault
provider) work unchanged against the same endpoint.

## Notes

* Health endpoint for readiness checks from other apps:
  `GET /v1/sys/health` (200 when serving; no credential needed).
* Everything is also reachable at `/v1/...` under the app's domain through
  Cloudron's reverse proxy with TLS terminated by the platform.
* Audit: every access from every consumer lands in
  `/app/data/audit/audit.log`.
* Do not embed the root token in any consumer. If a consumer needs broader
  rights, write it a broader policy; the root token is for break-glass.
