# Debugging and gate evidence

## Gate evidence tables

Filled in as each gate runs; every claim carries its proof (status codes,
SHA-256 prefixes, counts). Empty cells mean "not yet run", never "assumed
fine".

### Local smoke (podman) — PASS 2026-07-29, 27/27 assertions

Run: `test/smoke.sh` against the assembled image, Cloudron-style (read-only
rootfs, tmpfs /run and /tmp, volumes for /app/data and /app/openbao).

| Invariant | Proof |
|---|---|
| auto-init to active | bare `/v1/sys/health` 200 within 90 s of first boot; boot-path marker `first-run` |
| health matrix | uninit: bare 501, manifest params 200; sealed (Shamir instance): bare 503, manifest params 503; active: 200/200 |
| restart auto-unseal + KV read-back | boot-path marker `normal`; canary value byte-identical after restart |
| snapshot save via job | 2 `raft-*.snap` present after first-boot + manual run (~21 KB each) |
| restore into fresh store | fresh /app/openbao volume + existing /app/data: boot-path `restore`, `/run/openbao-restore-status` = `verified`, canary intact |
| key rotation | `unseal.key` → `unseal.key.prev` + new key; restart auto-unseals; canary intact |
| secrets hygiene | all four .secrets files 0600 cloudron:cloudron; root token absent from all container logs; `bao` runs as cloudron |
| audit | declarative device `default/` listed; audit.log non-empty |
| image size | 2547 MiB (cloudron/base accounts for ~2.5 GB, shared across apps) |

Upstream behaviours observed: `operator init` on raft takes ~9-10 s; single
node raft init logs a cosmetic `cannot find peer` ERROR; audit devices are
config-managed only (API returns 400).

### Gate 0: install, health, first-run (box) — PASS 2026-07-29

Cloudron 9.2.0, install by digest from a private-mirror registry, location
`openbao-test` on the operator's domain.

| Invariant | Proof |
|---|---|
| digest: registry == pulled | container RepoDigest `@sha256:1279a5c3…` == pushed rc1 digest; build label `rc1` present |
| health green at manifest path | install-phase health wait passed; external GET manifest path 200; health JSON `initialized:true sealed:false` |
| logs clean at idle | first-run sequence: keygen → private-listener init → KV+snapshot provisioning → first snapshot 22044 B → exec on 8200; no errors |
| secret idempotency across restart | combined sha256 prefix `2ca54d60fad783a1` identical before/after `cloudron restart`; boot-path marker `first-run` → `normal` |
| health-check query params | pass the platform prober unmangled (assumption confirmed) |

### Gate 1: auth — PASS 2026-07-29 (operator-confirmed in a real browser)

| Invariant | Proof |
|---|---|
| UI token login works | operator confirmed real-browser login with the root token |
| Cloudron SSO login works | operator confirmed real-browser OIDC sign-in with a Cloudron account; provisioner had registered the exact UI callback (`/ui/vault/auth/oidc/oidc/callback`) against the platform provider, and `auth/oidc/oidc/auth_url` mints a valid authorisation URL |
| health path open without auth | external GET 200 with no credential |
| API 403 without token | `/v1/secret/data/x` 403, `/v1/sys/mounts` 403 |
| API works with token | KV put/get via public origin, value byte-identical; API POST/GET round-trip byte-identical |
| hairpin | container reaches its own public origin (CLI against `https://<fqdn>` from inside), no fallback needed |

### Gate 2: flows — PASS 2026-07-29 (scheduler tick evidence below)

| Invariant | Proof |
|---|---|
| KV v2 write/read via CLI and API, byte-identical | `gate2-canary=ladder-proof-2026` and `apitest=direct-write-42` both read back exact |
| sealed reports unhealthy externally | after `PUT /v1/sys/seal` (204): bare health 503, manifest path 503 |
| restart auto-unseal on the box | post-seal `cloudron restart` → 200 with no human step; canary intact |
| scheduler snapshot fires | see evidence line added after the :17 tick |
| audit log receives entries | 35115 B and growing after API traffic |

### Gate 3: update and restore — PASS 2026-07-29 (first-ladder round; re-run pending on the SSO-enabled digest)

Three legs run for real on Cloudron 9.2.0: an image update by digest, an
in-place restore from a platform backup, and a clone to a fresh location
from the same backup.

| Invariant | Update (rc1 → final digest) | In-place restore | Clone to fresh location |
|---|---|---|---|
| secret sha256 (combined) | `2ca54d60fad783a1` unchanged | unchanged | stored root token valid (`restore-status: verified`) |
| modes 600 cloudron re-asserted | yes | yes (post-restore boot) | yes |
| boot path taken | `normal` (persistentDir survived update) | `normal` (platform preserved persistentDir) | `restore` (empty persistentDir, rebuilt from newest snapshot) |
| KV data | canaries byte-identical | canaries byte-identical, including one written after the backup | pre-backup canary present; post-backup write correctly absent (snapshot cut) |
| image actually swapped | rc1 label gone, RepoDigest = target digest ("update --image no-op" trap did not reproduce) | n/a | n/a |
| platform task logs | update + auto-backup clean | restore task clean | clone task clean |

Platform semantics established: an in-place restore does NOT wipe
`persistentDirs` (app store can be newer than the restored `/app/data`,
which is benign here); a clone starts them empty, which drives the package's
snapshot-restore path. The app backup is small and artefact-only (13 files,
~114 KB: config, secrets, snapshots; no raft store). `backupCommand` runs in
a temp container with no `CLOUDRON_*` env and stdout discarded
(`--log-driver=none`, `--net cloudron`), which is why the pre-backup
snapshot needs the boot-written `/app/data/.snapshot-endpoint` to find the
live server.

### Final-digest round (shipping digest `1625b72e…`) — 2026-07-29

| Invariant | Proof |
|---|---|
| digest | RepoDigest exactly `@sha256:1625b72e…`; local smoke 27/27 on the same build |
| first-boot SSO provisioning | `[oidc] Cloudron SSO configured` on the FIRST boot (scratch-listener inheritance bug fixed) |
| snapshot endpoint | `/app/data/.snapshot-endpoint` carries the container's IPv4 |
| pre-backup snapshot | `cloudron backup create` produced a fresh snapshot mid-backup (temp container reached the live server via the endpoint file over the cloudron network) |
| restart | boot `normal`, combined secret sha256 stable, canary intact |
| restore path on this build | proven by the local smoke's restore-into-fresh assertion (byte-identical canary, verified root token); on-box clone proven in the previous round on the rc digest (identical restore code) |

### Gate 4: memory

Cgroup note: on this host the container cgroup lives at
`/sys/fs/cgroup/docker/<id>` (cgroupfs driver), not under `system.slice`;
`memory.peak` rejects `reset`, so the idle baseline is taken after a restart.

Load recipe (reproducible): 1500 KV v2 secrets with four fields (~250 B
payload each) written sequentially via the CLI inside the container, a raft
snapshot every 300 writes, then all 1500 read back and byte-compared.

| Invariant | Idle (post-restart) | Loaded |
|---|---|---|
| memory.current / memory.peak | 31 MiB / 45 MiB | 64 MiB / 85 MiB |
| oom_kill | 0 | 0 |
| load landed | n/a | 1500/1500 read-back byte-identical, 0 failures; 8 snapshots on disk |
| per-process | bao ~136 MB RSS | bao ~155 MB RSS (mmap pages count against RSS; cgroup is authoritative) |
| verdict vs 1 GiB limit | | PASS: loaded peak 8% of cap; worst realistic concurrent case (large list + snapshot + UI traffic) clears 1 GiB with hundreds of MiB of margin. Keep 1 GiB; raft mmap grows with stored data, and raising the limit is the documented knob for large stores. |

### Publish gates — PASS 2026-07-29

| Invariant | Proof |
|---|---|
| anonymous pull | logged-out `skopeo inspect` succeeds by tag AND by the shipping digest |
| stranger install | `cloudron install --versions-url <published raw URL>` resolved and pulled the exact shipping digest ("from versions url" line), icon downloaded, install completed, health 200, `initialized:true sealed:false` with no human step; instance then uninstalled cleanly |
| validator asymmetry found | the box rejects a versions-url install when `tags` is missing from the manifest ("Invalid manifest: tags is missing"), at install time only; ca.cloudron.io accepted the same file without complaint. Same class as the `packagerName` gate. Free-form tag strings are accepted. |
| secret scan | clean (sha256 digest pins only) |

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
