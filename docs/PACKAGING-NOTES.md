# Packaging notes: verified versus assumed

Public log of what was confirmed empirically versus carried by assumption,
newest first. Techniques only; no host specifics. See `docs/DEBUGGING.md` for
gate evidence tables.

## 2026-07-29 local smoke round (podman, Cloudron-style run)

**Verified against the running image (OpenBao 2.6.1):**

* Raft on-disk layout under the configured `path`: `vault.db` (the name is
  inherited), `raft/raft.db`, and `raft/snapshots/` (the internal
  create-rename-reap churn directory that justifies keeping the store out of
  the live backup walk). Boot-path detection must test `raft/raft.db`, not
  `<path>/raft.db`.
* `bao operator init` against raft storage takes about 9 to 10 seconds.
  Anything driving `PUT /v1/sys/init` needs a timeout comfortably above
  that; a 10 second client timeout times out at exactly the wrong moment,
  and the barrier still initialises server side, which would strand a real
  operator with keys they never received.
* Single-node raft init logs a scary-looking but apparently cosmetic
  `[ERROR] core: failed to unlock initialization lock: error="cannot find
  peer"`, and scratch auto-seal inits log `[WARN] core: post-unseal upgrade
  seal keys failed: error="no recovery key found"`. Both accompany fully
  functional outcomes; noted as a question to put to upstream.
* **Audit devices cannot be created via the API** (HTTP 400 `cannot enable
  audit device via API; use declarative, config-based audit device
  management instead`; disabled upstream since v2.3.2). The declarative
  stanza works: `audit "file" "default" { options { file_path = "..." } }`,
  applied at restart and SIGHUP.
* The CLI subcommand is `bao token renew` (self-renew when no argument);
  there is no `renew-self` subcommand.
* The init API response carries `keys` (hex) and `keys_base64`; there is no
  `keys_b64` field.
* Static seal, key as a raw 32-byte `file://`: generation with
  `openssl rand -out key 32` accepted; auto-unseal proven across container
  restarts, across a snapshot restore into a fresh store, and across a key
  rotation using the `previous_key` stanza with content-derived key ids.
* The whole zero-touch cycle proven end to end locally: first boot
  initialises on a private listener, credentials land 0600, hourly-style
  snapshot job produces artefacts, a fresh store next to snapshots rebuilds
  itself and the stored root token remains valid, and the canary KV secret
  survives every one of restart, restore and rotation byte-identically.
* Test-harness note for other packagers: rootless podman's journald log
  driver flushes lazily, so `podman logs | grep` assertions race the boot
  they are checking; retry the grep or assert on behaviour instead.

## 2026-07-29 design round

**Verified (against the Cloudron 9.2 platform source):**

* App environment variables are stored in plain text in the platform
  database (`appEnvVars` table; the write path applies no encryption), and
  the full app object including `env` is serialised into `config.json`
  inside every per-app backup, from where a restore reads it back. An
  `env://` unseal key is therefore in the same trust domain as a
  `file:///app/data` key: both are admin-readable and both ride the app
  backup. This finding reshaped the seal design (ADR 0002).
* The health monitor treats only 5xx and connection errors as unhealthy;
  2xx, 3xx and 4xx all count healthy. An unhealthy-but-running app is
  marked "not responding" about 20 minutes after last being seen healthy,
  with a notification; nothing in the platform restarts a running container
  for failing its health check (ADR 0003).

**Verified (against upstream OpenBao 2.6.1 releases and documentation):**

* `file` storage: deprecated 2.6.0, removed 2.7.0. Raft is the only
  production backend. `cluster_addr` is mandatory with raft even on a
  single node.
* mlock is removed from OpenBao; `disable_mlock = false` is a fatal
  startup error (confirmed in `configutil` source). No mlock capability,
  no setcap, no config line (ADR 0004).
* `/v1/sys/health` default codes 200/429/501/503 and the five overridable
  parameters (`standbyok`, `activecode`, `standbycode`, `sealedcode`,
  `uninitcode`). Vault Enterprise parameters do not exist here.
* The static seal is built in, not deprecated, and accepts `file://` and
  `env://` key sources; 32 bytes, AES-256-GCM.
* Release artefacts ship `checksums.txt` with a detached GPG signature;
  the signing key fingerprint is published on the install docs page.

**Assumed, to verify at the local smoke gate:**

* Key file encoding: upstream's own example generates the `file://` key
  with `openssl rand -out key 32` (raw bytes), and the docs say literal
  values may be base64 or hex. The package uses raw bytes to match the
  documented example. The smoke test proves it.
* `operator init` against a static-seal server returns recovery keys and
  auto-unseals immediately without a restart.
* `operator raft snapshot restore -force` into a freshly initialised
  scratch cluster adopts the snapshot's data and re-unseals under the same
  static key.

**Assumed, to verify on the box (gate ladder):**

* The `scheduler` addon executes the command inside the live app container
  (so `localhost:8200` is reachable from the snapshot job).
* `backupCommand` runs in a temporary container where the live server is
  not on localhost; whether that container can reach the app's public
  origin decides if pre-backup snapshots work (the job is best-effort
  either way).
* `persistentDirs` content survives update and restart but comes back
  empty after a restore into a new location; the boot-time snapshot
  restore covers it.
* Health-check query parameters in `healthCheckPath` pass through the
  platform's health prober unmangled.
