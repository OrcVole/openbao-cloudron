# ADR 0005: No Cloudron SSO in v1; OpenBao's native auth is the front door

Status: accepted (2026-07-29)

## Context

OpenBao has a complete authentication system of its own (token, userpass,
OIDC, LDAP methods), fine-grained policies, and both a human UI and a
programmatic API on the same port. The Cloudron options would be:

* `proxyAuth`: wrong here. It would wall the Vault-compatible API behind an
  interactive login, breaking every CLI and client library, and OpenBao's
  own auth would still exist behind it. The house rule is proxyAuth only for
  apps with no auth of their own.
* The `oidc` addon: plausible and attractive (Cloudron users signing in to
  the OpenBao UI via Cloudron), wiring `CLOUDRON_OIDC_*` into OpenBao's OIDC
  auth method. But the method's role/policy mapping and the UI callback path
  need empirical verification, auth methods are persistent server state
  (they belong to the operator's data, not to boot-time config the package
  rewrites), and a half-right SSO button on a secrets manager is worse than
  none.

## Decision

v1 ships with no auth addon. The front door is OpenBao's own auth; first
login uses the root token the package stored at install, and the checklist
directs the operator to create a proper admin method. The health endpoint is
unauthenticated by design (verified), so the health check needs no
credentials.

## Revisit

A minor release can add opt-in Cloudron OIDC once verified end to end on a
real install: enable the OIDC auth method against `CLOUDRON_OIDC_*`, confirm
the UI callback path OpenBao actually uses, and decide the default role's
policy (sensible default: a policy with no secret access, so SSO users exist
but see nothing until granted). The addon addition must be tested as an
update to an existing install, not only fresh.
