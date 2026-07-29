# OpenBao for Cloudron

[OpenBao](https://openbao.org) packaged as a Cloudron app: an open source
identity-based secrets and encryption management system, the Linux Foundation
stewarded fork of HashiCorp Vault. The package's purpose is a secrets manager
that stays usable on a platform that restarts and updates apps unattended.

This is an unofficial community package, not affiliated with or endorsed by
the OpenBao project, the Linux Foundation, or Cloudron.

## What you get

* OpenBao with integrated raft storage and the web UI, on a single node.
* **Auto-unseal by default** using OpenBao's built-in `static` seal. The
  instance survives restarts and Cloudron's automatic updates with no manual
  unseal ceremony.
* **Zero-touch first start**: the package initialises OpenBao, mounts a KV v2
  secrets engine at `secret/`, enables a file audit device, and stores the
  root token and recovery keys in `/app/data/.secrets` for you to collect.
* **Consistent backups**: hourly raft snapshots (OpenBao's supported backup
  mechanism) are written into `/app/data/snapshots` and ride Cloudron's
  backups; a restore or clone rebuilds the store from the newest snapshot
  automatically.
* A health check that reports a sealed instance as unhealthy, so the Cloudron
  dashboard tells the truth.

## Install

From the Cloudron App Store's community section, or:

```
cloudron install --versions-url https://raw.githubusercontent.com/OrcVole/openbao-cloudron/main/CloudronVersions.json --location bao.example.com
```

## Security model, honestly stated

Auto-unseal means the 32-byte unseal key lives at
`/app/data/.secrets/unseal.key`, on the same server as the data it decrypts,
and inside every app backup. Consequences:

* A stolen **encrypted** Cloudron backup is safe; enable backup encryption.
* A stolen **unencrypted** backup or disk image is readable. The seal then
  protects nothing; treat backup encryption as part of this package's
  security model.
* Nothing protects against a hostile root or Cloudron admin on the server
  itself. That is true of every seal type without external key management.

Upstream's guidance is that the static seal is appropriate "when an existing
source of trust already exists in the operating environment". On a Cloudron,
that source of trust is the server and its (encrypted) backups. If you would
rather perform manual unsealing with Shamir key shares, see below.

Also note: OpenBao no longer uses `mlock`, so its memory can reach swap on
hosts with unencrypted swap. If that matters to you, encrypt or disable swap
on the server (this is host-level configuration, outside the app's control).

## Day-to-day

* UI: `https://your.domain/ui/`. First login: method **Token**, using
  `/app/data/.secrets/root-token`. Create a proper admin auth method
  (`userpass`, `oidc`, `ldap`) and keep the root token for emergencies.
* CLI from your machine: install the `bao` CLI, then
  `export BAO_ADDR=https://your.domain` and `bao login`.
* API: Vault-compatible, `https://your.domain/v1/...`. Existing Vault client
  libraries work unchanged.
* Audit log: `/app/data/audit/audit.log`, rotated at 64 MB (one generation
  kept).

## Configuration

Server configuration is a merged directory, `/app/data/config/`:

* `main.hcl` is yours. It is generated once on first start and never touched
  again; edits survive restarts, updates, backups and restores.
* `zz-managed.hcl` is the package's. It is regenerated on every start and
  carries the listener, `api_addr` and the seal stanza. Do not edit it; do
  not redefine those stanzas in `main.hcl`.

## Backups and restore

The raft store itself lives on `/app/openbao` (a Cloudron `persistentDirs`
path), deliberately excluded from the file backup: copying a live embedded
database file is not crash-consistent, and OpenBao's own supported backup is
a raft snapshot. What rides the Cloudron backup is `/app/data`, which
contains the configuration, the credentials, and the snapshots.

* Snapshots are taken hourly (at minute 17), before each Cloudron backup when
  possible, and pruned to the newest 24.
* On restore or clone, the app finds an empty store next to existing
  snapshots and rebuilds from the newest one, then verifies the restored data
  accepts the stored root token. Writes made after the last snapshot are not
  in the backup.
* Before risky changes, take a manual snapshot from the app's Web Terminal:
  `export BAO_TOKEN=$(cat /app/data/.secrets/root-token)` then
  `bao operator raft snapshot save /app/data/snapshots/raft-manual-$(date +%s).snap`

## Unseal key rotation

The seal key id is derived from the key material, so rotation is a file
operation, in the app's Web Terminal:

```
cd /app/data/.secrets
mv unseal.key unseal.key.prev
openssl rand -out unseal.key 32
chmod 600 unseal.key && chown cloudron:cloudron unseal.key
```

Then restart the app. The package writes both keys into the seal stanza
(`previous_key`/`current_key`) and OpenBao re-wraps on start. After a
successful restart and a fresh snapshot, `unseal.key.prev` can be deleted.
Keep an off-server copy of the current key at all times; snapshots taken
under an old key need that key to restore.

## Shamir (manual unseal) mode

For operators who want the unseal key material entirely off the server:

* **Fresh install**: set the app environment variable `OPENBAO_SEAL=shamir`
  (App, then Settings, then Environment) before the app's very first start,
  or reinstall with it set. The package then skips key generation and
  automatic initialisation; initialise and unseal via the UI as upstream
  documents.
* **Migration in either direction** uses OpenBao's seal migration: to leave
  static seal, set `OPENBAO_SEAL_DISABLED=true` (the package marks the seal
  `disabled = "true"`), restart, and run `bao operator unseal -migrate` with
  the recovery keys from `/app/data/.secrets/init.json`; afterwards create
  the marker file `/app/data/.secrets/SHAMIR` and remove the key files.
  Migration back to static is the reverse (remove the marker, restart to
  generate a key, and migrate with `-migrate`). See the OpenBao seal
  documentation before attempting either.

Trade-offs in Shamir mode, stated plainly: the app reports unhealthy while
sealed (Cloudron flags it about 20 minutes after every restart until you
unseal), automatic snapshots stop working while sealed, and a restore from
backup is a manual procedure (`bao operator raft snapshot restore` after you
initialise and unseal a fresh store). Auto-unseal exists because a secrets
manager that is down after every automatic update is not much of a secrets
manager; Shamir mode is there because the choice is yours to make.

## Memory

The default memory limit is 1 GB. OpenBao's raft storage maps its database
into memory, so the practical footprint grows with stored data; raise the
limit in the app's settings if you store a large number of secrets or run
heavy workloads.

## Licence

OpenBao is distributed unmodified under the Mozilla Public License 2.0
(`LICENSE`, also shipped in the image as `/app/code/LICENSE-openbao`); source
is at https://github.com/openbao/openbao. The packaging in this repository is
likewise MPL-2.0. See `NOTICE`.
