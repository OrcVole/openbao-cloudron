# Packaging notes: verified versus assumed

Public log of what was confirmed empirically versus carried by assumption,
newest first. Techniques only; no host specifics. See `docs/DEBUGGING.md` for
gate evidence tables.

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
