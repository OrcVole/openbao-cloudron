# ADR 0002: Static seal by default, package-driven initialisation

Status: accepted (2026-07-29)

## Context

The package exists because a secrets manager that cannot auto-unseal is
barely usable on Cloudron: the platform restarts and auto-updates apps
unattended, and every restart of a Shamir-sealed store leaves it answering
requests but serving nothing until a human pastes key shares. The existing
Vault package has exactly this defect.

OpenBao v2.4+ ships a built-in `static` seal: a 32-byte key, supplied as a
literal, `env://` or `file://`, no external KMS. Upstream recommends it
"when an existing source of trust already exists in the operating
environment".

The obvious placement question, key file in `/app/data` versus a Cloudron
environment variable, was investigated against the platform's own source
(Cloudron 9.2): app environment variables are stored in plain text in the
box database (`appEnvVars` table, no encryption in the write path) and are
serialised into `config.json` inside every per-app backup. An environment
variable is therefore in the same trust domain as a file in `/app/data`:
both are readable by Cloudron admins and both ride the app backup. The
meaningful mitigation for backup theft is Cloudron's backup encryption, not
key placement.

An earlier draft of this design defaulted to Shamir to avoid choosing a
security model for the operator. Two findings changed that: the placement
finding above (the "safer" env option is not safer), and the platform
behaviour that a sealed instance is flagged unhealthy and notified on every
restart, which in Shamir mode means routine false alarms for a state the
operator caused deliberately.

## Decision

* Default seal: `static`, key generated on first boot with
  `openssl rand -out unseal.key 32` into `/app/data/.secrets` (0600,
  re-asserted every boot). The seal key id is the first 8 hex characters of
  the key's SHA-256, so id-follows-key is guaranteed and rotation is a file
  swap (`unseal.key.prev` becomes `previous_key`).
* First boot initialises OpenBao automatically: `operator init` (5 recovery
  shares, threshold 3), root token and full init output stored in
  `/app/data/.secrets`, KV v2 mounted at `secret/`, and a minimal-policy
  periodic token created for the snapshot job. The file audit device is
  declared declaratively in the generated `main.hcl` because OpenBao
  disables audit device creation via the API (since v2.3.2).
  The post-install checklist directs the operator to copy the recovery
  material off the server and enable backup encryption.
* Package-driven init was chosen over OpenBao's declarative `initialize`
  stanza because the stanza revokes the root token after use, which locks
  the operator out unless the stanza also provisions an admin auth method;
  retaining the root token for the operator is the simpler and safer v1.
* Shamir remains available: `OPENBAO_SEAL=shamir` before first start, or the
  documented seal migration procedure in either direction. Its trade-offs
  (flagged unhealthy while sealed, no automatic snapshots while sealed,
  manual restore procedure) are documented rather than hidden.

## Consequences

* Install-to-usable is zero-touch, which is the package's reason to exist.
* The unseal key, root token and recovery keys live on the server and in
  its backups until the operator moves them; POSTINSTALL and the checklist
  make the off-server copy the first action. Backup encryption is
  recommended in the same breath. The threat model is stated plainly in
  README and SECURITY.
* The security-conscious path is opt-in rather than default. This is a
  deliberate reversal of the earlier draft, justified by the placement
  finding, and it matches how Cloudron packages are expected to behave
  (working immediately after install).
