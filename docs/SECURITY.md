# Security notes

Threat model and hardening for the OpenBao Cloudron package. Read alongside
README's "Security model, honestly stated".

## What protects what

| Scenario | Protected by | Notes |
|---|---|---|
| Stolen encrypted Cloudron backup | Cloudron backup encryption | The backup contains the unseal key and the snapshots it decrypts; encryption at the backup layer is the control. Enable it. |
| Stolen unencrypted backup | Nothing | Stated plainly in POSTINSTALL; the checklist pushes backup encryption. |
| Stolen disk / VPS image | Disk or backup encryption at host level | Same reasoning as backups. |
| Hostile Cloudron admin or host root | Nothing | True for every seal type without external KMS; also true of the Vault package. |
| Compromised app container (read of `/app/data`) | Nothing for data-at-rest secrets | The key and store are both reachable; OpenBao policies still gate API access. |
| Secrets paged to swap | Host swap encryption / `swapoff` | mlock is gone from OpenBao by design; host-level control. |
| Casual exposure in logs / process lists | Package discipline | Keys and tokens are never logged and never passed as CLI arguments by the package. |

## Choices made

* Generated credentials live in `/app/data/.secrets`, 0700 directory, 0600
  files, cloudron:cloudron, re-asserted on every boot because a Cloudron
  restore resets modes and ownership.
* The static seal key id is derived from the key's SHA-256, so a key/id
  mismatch (which would brick unsealing) cannot happen by operator error.
* The snapshot job authenticates with a dedicated periodic token carrying a
  single-path read policy (`sys/storage/raft/snapshot`), not the root token.
* The listener trusts `X-Forwarded-For` only from the Cloudron proxy IP, so
  audit logs record real client addresses without letting clients spoof
  them; requests without the header fall back to their source address.
* The server process runs as the unprivileged `cloudron` user; root is used
  only for boot-time setup. Core dumps are disabled (`ulimit -c 0`).
* No telemetry leaves the instance: OpenBao's telemetry stanza is local
  metrics sinks only, and none is configured.

## Residual risks, accepted and stated

* Auto-unseal means possession of the server or its unencrypted backups is
  possession of the secrets. The alternative default (Shamir) trades this
  for a store that is down after every unattended update; operators who
  want that trade get it via the documented opt-in.
* The root token remains valid until the operator revokes it; the checklist
  tells them to create their own admin method. Automatically revoking it
  would lock out an operator who skipped the checklist, which is worse.
* `/app/data/.secrets/init.json` (recovery shares) stays on the server until
  the operator copies and deletes it. The README of that directory says so.
