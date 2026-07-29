# Debugging and gate evidence

## Gate evidence tables

Filled in as each gate runs; every claim carries its proof (status codes,
SHA-256 prefixes, counts). Empty cells mean "not yet run", never "assumed
fine".

### Local smoke (podman)

| Invariant | Proof |
|---|---|
| auto-init to active | |
| health matrix uninit/sealed/active, bare and manifest params | |
| restart auto-unseal + KV read-back | |
| snapshot save via job | |
| restore into fresh store + root token valid + KV read-back | |
| key rotation restart | |
| secrets 0600 cloudron; absent from logs | |
| image size | |

### Gate 0: install, health, first-run (box)

| Invariant | Proof |
|---|---|
| digest: registry == pulled | |
| health green at manifest path | |
| logs clean at idle | |
| secret idempotency across restart (sha256 stable, existing-secrets branch) | |

### Gate 1: auth

| Invariant | Proof |
|---|---|
| UI token login works | |
| health path open without auth | |
| API 403 without token, works with token | |

### Gate 2: flows

| Invariant | Proof |
|---|---|
| KV v2 write/read via CLI and UI, byte-identical | |
| restart auto-unseal on the box | |
| scheduler snapshot fires (crontab minute 17) | |
| audit log receives entries | |

### Gate 3: update and restore

| Invariant | Update | Restore |
|---|---|---|
| secret sha256 (unseal.key, root-token) | | |
| modes 600 cloudron re-asserted | | |
| boot path taken | | |
| KV data intact | | |
| persistentDir behaviour | | |
| backup task log clean | | |

### Gate 4: memory

| Invariant | Idle | Loaded |
|---|---|---|
| memory.current / memory.peak | | |
| oom_kill | | |
| verdict vs 1 GiB limit | | |

## Recovery recipes

**Crash-looping app (bad config edit):** `cloudron exec` fails with 409 while
looping. Use debug mode: `cloudron stop --app <loc>`, `cloudron debug --app
<loc> sleep 86400`, `cloudron start --app <loc>`, fix the file via
`cloudron exec`, then `cloudron debug --app <loc> --disable`.

**Sealed and will not auto-unseal:** almost always a missing or wrong
`/app/data/.secrets/unseal.key`. The seal stanza's `current_key_id` is the
first 8 hex chars of the key's SHA-256; compare against your off-server copy.

**Restore did not adopt the snapshot:** check the boot log for the
`restoring` and `restore verified` lines. A failed restore wipes the scratch
store and exits so the next start retries; the newest `.snap` in
`/app/data/snapshots` is what it will use.

**Health shows not responding:** `curl https://<domain>/v1/sys/health` and
read the JSON: `sealed`, `initialized`, `standby` tell you which state you
are in; the dashboard flag follows this endpoint's status code.
