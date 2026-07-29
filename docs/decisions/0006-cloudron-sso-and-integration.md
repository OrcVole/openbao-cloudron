# ADR 0006: Cloudron SSO via the oidc addon; integration surface

Status: accepted (2026-07-29). Amends ADR 0005, whose caution ("no half
verified SSO on a secrets manager") is preserved by how this is wired, and
whose "revisit" plan this implements.

## Context

The package should be a good citizen of the Cloudron ecosystem: Cloudron
users expect the platform's single sign-on where it makes sense, and other
apps on the box should be able to consume OpenBao as their secrets backend.
ADR 0005 deferred SSO because the callback path and role mapping needed
empirical verification; the gate ladder now provides a live instance to
verify against, so the deferral no longer buys anything.

## Decision

* Declare the `oidc` addon with `loginRedirectUri` on OpenBao's UI callback
  path (`/ui/vault/auth/oidc/oidc/callback`, verified at the gate), plus
  `optionalSso: true` so operators can install without Cloudron user
  management at all.
* A boot-time provisioner (`configure-oidc.sh`, forked before the server
  exec, idempotent, re-applied every boot because addon credentials can
  change) enables the OIDC auth method with unauthenticated listing (the
  login screen shows the option), points it at `CLOUDRON_OIDC_*`, and
  creates one role `cloudron` with `token_policies="default"`.
* **SSO users get no secret access by default.** The `default` policy lets
  them exist and log in, nothing more. Granting read access to anything is
  a deliberate operator act (documented in `docs/INTEGRATIONS.md`). This is
  how a secrets manager should treat a whole-directory login grant.
* Machine consumers use AppRole with per-consumer minimal policies, never
  the root token; `docs/INTEGRATIONS.md` carries the recipes. The UI SSO
  and the programmatic API are independent surfaces; SSO walls nothing.
* Shamir mode: the provisioner skips (no stored root token) and the
  operator wires OIDC themselves if wanted.

## Consequences

* Fresh installs with user management get a working "sign in with
  Cloudron" out of the box, with a safe-by-default authorisation posture.
* The provisioner needs the stored root token at boot; if the operator
  revokes it (as POSTINSTALL suggests they eventually might), the
  re-application stops with a logged warning and the existing OIDC config
  simply persists. Rotating the addon's client secret after root-token
  revocation requires a manual `bao write auth/oidc/config`; documented.
* CLI OIDC login against Cloudron is out of scope (localhost redirect URIs
  cannot be registered with the platform's provider); tokens, userpass and
  AppRole cover CLI and machines.
