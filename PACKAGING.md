# Packaging OpenBao for Cloudron: what we learned

The narrative companion to this package: design lessons, verified platform
behaviour, and observations about upstream, written for anyone packaging an
embedded-datastore app for Cloudron (or deriving an OpenBao package from a
Vault one). The evidence log behind it is `docs/PACKAGING-NOTES.md`
(verified versus assumed, newest first) and the design decisions are ADRs in
`docs/decisions/`.

## What helped

* **Verifying platform behaviour against the platform's own source instead
  of folklore.** Two of this package's three central design decisions turned
  on facts that are not in the docs: what the health monitor counts as
  unhealthy, and where app environment variables actually live. Both were
  checkable, and both reversed an earlier draft of the design.
* **Keeping the seal decision reviewable.** Short architecture decision
  records (`docs/decisions/`) meant that when a finding overturned a choice,
  the reversal was a paragraph in an existing document rather than an
  argument with a past self.
* **A build-time verification gate.** The Dockerfile verifies the upstream
  release tarball twice: the GPG signature on `checksums.txt` against a
  pinned key fingerprint, and an independently pinned SHA-256 of the
  tarball. The signature proves the release chain; the pinned digest is a
  record in our own history that survives an upstream key rotation.
* **A single-binary upstream.** OpenBao ships one static-ish `bao` binary in
  a release tarball, so there is no multi-stage image scavenging and no
  supervisor. The package is the binary plus a `start.sh` state machine.
* **Marker files instead of log greps.** `start.sh` writes
  `/run/openbao-boot-path`, `/run/openbao-seal-mode` and
  `/run/openbao-restore-status` on every boot. Tests assert on those rather
  than racing a log flush, and they are genuinely useful for support too.

## What was difficult

* **The two obvious Vault-era moves are now traps.** `file` storage is
  deprecated in OpenBao 2.6 and removed in 2.7 (raft is the only production
  backend), and mlock is gone from OpenBao entirely, so a `disable_mlock`
  line copied from a Vault template is a **fatal startup error**. Anyone
  deriving an OpenBao package from an existing Vault package will hit both.
* **Backing up an embedded database that the platform copies live.** Raft
  stores data in bbolt, which is memory-mapped, and the raft layer creates
  and reaps internal snapshot directories. Neither survives a live
  filesystem walk safely. The fix was structural rather than mitigating:
  put the store on a `persistentDirs` path (survives restart and update,
  excluded from the file backup) and make app-native snapshots the backup
  artefact, with a boot-time restore path for the
  empty-store-next-to-snapshots case. See ADR 0001.
* **Sequencing first-run provisioning safely.** Initialising, mounting KV,
  minting a limited snapshot token and taking a first snapshot all have to
  happen before the public port serves anything. The package does that work
  against a private listener on `127.0.0.1:8299` and only then execs the
  real server on `0.0.0.0:8200`.
* **`operator init` on raft takes about 9 to 10 seconds.** Anything driving
  it needs a timeout comfortably above that. A 10 second client timeout
  fails at the worst possible moment: the barrier initialises server side
  anyway, so you get an initialised server whose keys nobody received.
* **Audit devices cannot be enabled through the API.** OpenBao disabled
  that route upstream (since v2.3.2); the declarative `audit` stanza in the
  config file is the way, and it applies at restart and on SIGHUP.
* **Rootless podman's journald log driver flushes lazily**, so
  `podman logs | grep` assertions race the boot they are checking. Assert
  on behaviour or marker files.

## Platform behaviour verified on Cloudron 9.2

None of this is in the Cloudron docs today; all of it was verified against
the 9.2 box source or empirically on a live box, and all of it is
load-bearing for a package like this one.

* **Health monitor semantics.** Only 5xx responses and connection errors
  count as unhealthy; 2xx, 3xx **and 4xx** all count healthy. An
  unhealthy-but-running app is marked "not responding" roughly 20 minutes
  after it was last seen healthy, with a notification, and nothing restarts
  a running container for a failing health check (the restart loops
  packagers see in the wild are the install and startup phase, where the
  port is not yet bound). Query parameters in `healthCheckPath` pass
  through the prober unmangled. See ADR 0003.
* **App environment variables are not a secrets boundary.** They are stored
  in plain text in the box database, and the whole `env` object is
  serialised into `config.json` inside every per-app backup, from where a
  restore reads it back. `cloudron env` is the same trust domain as a file
  under `/app/data`; do not design around it being safer. See ADR 0002.
* **`backupCommand` runs blind; the scheduler does not.** The `scheduler`
  addon execs its command inside the live container (as root, so anything
  it creates needs an ownership sweep on the next boot). `backupCommand`
  runs in a separate temporary container — `docker run` on the app image,
  joined to the cloudron network, with `/app/data` and the persistentDirs
  mounted, no `CLOUDRON_*` environment, and `--log-driver=none` so stdout
  vanishes. It can neither reach the live server on localhost nor learn the
  app's address from the environment. The working pattern here: the
  entrypoint writes the container's own IPv4 into
  `/app/data/.snapshot-endpoint` at every boot, and the backup job reads it
  back over the shared mount, so a fresh snapshot lands in every backup
  seconds before the file walk.
* **`persistentDirs` semantics differ by operation.** An update and an
  in-place restore both preserve the persistent dir, so the store can end
  up newer than the restored `/app/data`; a clone to a new location starts
  it empty. Boot logic has to handle both, and only the second is the
  snapshot-restore path.

## If anyone from Cloudron reads this

Friendly asks, all documentation-shaped, arising from the platform section
above:

* Documenting the health monitor's semantics, the `backupCommand`
  temporary container, and the fact that app environment variables are not
  a secrets boundary would spare every packager the reverse-engineering
  this package needed. (A longer-term nicety: encrypting env vars at rest.)
* A supported pre-backup hook that runs **inside the live app container**,
  immediately before the file walk, would let apps with embedded
  datastores hand the platform a consistent artefact without the
  address-file dance described above.
* Backup walker resilience is worth a look independently: a directory
  disappearing mid-walk should degrade to skipping that app, not abort the
  whole server's backup run.

## Observations about upstream OpenBao

Small, documentation-shaped notes from the packaging work, recorded here
for other packagers; anything raised with upstream itself is written by
hand per their contribution policy.

* The `file` storage backend docs page carries no deprecation banner, even
  though the changelog deprecates it in 2.6.0 for removal in 2.7.0.
* The static seal is hard to discover from the seal docs landing page,
  despite being exactly the right answer for single-node self-hosters: a
  built-in auto-unseal needing no external KMS, no cloud account and no
  second service.
* Single-node raft init logs a cosmetic-looking
  `[ERROR] core: failed to unlock initialization lock: error="cannot find
  peer"`, and scratch auto-seal inits print `[WARN] core: post-unseal
  upgrade seal keys failed: error="no recovery key found"`. Both accompany
  fully functional outcomes.
* `PUT /v1/sys/init` against raft takes about 10 seconds (see above). The
  init response field is `keys_base64`, easily guessed wrong as `keys_b64`.
* `POST /v1/sys/audit/...` returns 400 by design; tooling and tutorials
  written for Vault all use the API route, so the first encounter is
  usually a failure. The declarative `audit` stanza works, including on
  SIGHUP.
