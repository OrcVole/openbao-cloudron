# ADR 0007: bundle the four extracted engines as pinned plugins, and carry old mounts over by tuning

Status: accepted (2026-10-22). Operator decision: bundle all four plugins, and accept a documented
workaround for command-line LDAP login until upstream fixes it.

## Context

OpenBao 2.7 removed `auth/ldap`, `auth/radius`, `auth/kerberos` and `secrets/ldap` from the main
binary (GH-3882). They continue in `openbao/openbao-plugins`, first released as v0.1.0 on 2026-10-02.
Package 1.0.4 stayed on OpenBao 2.6.4 so installs using them kept working; upstream support for 2.6 is
ending, so 1.1.0 moves to 2.7.1. Strangers' installs on the public feed may use any of the four, so all
four are bundled (about 70 MB).

## Decision

1. **Dockerfile.** Each plugin tarball is downloaded at v0.1.0, its detached signature is verified with
   the same pinned OpenBao release key as the main binary (the signature is over the tarball), its sha256
   is checked against the release `checksums-<name>.txt` and against a value pinned in the Dockerfile, and
   the unpacked binary's sha256 is pinned too. Binaries go to `/app/code/plugins`, root-owned, 0755, not
   writable by the server user. A build gate runs every binary (a plugin run outside a server prints
   upstream's "This binary is a plugin" refusal, which proves it loads on this base).
2. **Registration.** `start.sh` writes `plugin_directory`, `plugin_auto_register = true` and one
   declarative `plugin` stanza per binary (command, version, sha256sum) into `zz-managed.hcl`, which is
   regenerated every start, so existing installs receive it with no `main.hcl` edit. A binary that is
   not on disk is left out of the file, because a missing binary named in a stanza aborts unseal.
3. **Existing mounts: `tune -plugin-version`, automated.** `migrate-plugins.sh` runs once per start in the
   background after the server is up and does nothing unless a mount of the four engines reports no
   plugin version.

## Measured facts (OpenBao 2.7.1, 2026-10-22)

- A mount created on 2.6.x stores the builtin version (`v2.6.4+builtin.bao`) and an empty
  `plugin_version`. On 2.7.1 with the plugins registered declaratively at `v0.1.0`, it still cannot find
  its engine: `plugin not found in the catalog: ldap`, `skipping plugin-based auth entry`. The server
  starts and unseals; the mount is listed, every request to it fails, its stored data is untouched.
  So declarative registration alone does NOT carry an existing mount over (the first candidate, as
  predicted by the recon).
- **Declarative stanzas were not registered at all until `plugin_auto_register = true` was written
  explicitly.** The documented default (true) is lost when the server merges the files of a config
  directory (our `main.hcl` plus `zz-managed.hcl`): the stanzas are parsed, the registration pass is
  skipped silently (`plugins=[]` in the log). The package therefore states the key itself.
- `bao auth tune -plugin-version=v0.1.0 <mount>/` (and `bao secrets tune` for `secrets/ldap`) followed by
  `bao plugin reload -mounts=auth/<mount>/` revives the mount: same user, same policies, same entity id,
  configuration unchanged, and it survives a restart. This was the first candidate tried and it proved
  the old mount works, so the others (unversioned registration through the API at boot) were not needed.
- With no plugins bundled (negative control), the server starts and unseals, dead mounts stay listed, and
  adding the plugin later plus the tune revives the same mounts with no data loss.

## How the carry-over stays narrow

It reads the mount lists with the stored root token, mints a five-minute orphan token whose policy allows
only `update` on the tune path of each mount that needs it and on `sys/plugins/reload/backend`, uses that
token, revokes it, and deletes the policy. No token or policy outlives the run, no value is printed, and
the step is idempotent (a tuned mount reports a version and is skipped). Without a stored root token it
logs one line and the operator runs the documented tune command. Rejected for now: registering the
plugins unversioned through the API at boot (needs a standing high-power or catalog-admin token, and
leaves plugin upgrades outside the declarative path).

## Consequences

- The package root-trusts the stored root token once, at update time, for installs that have such mounts.
- Restoring a backup taken on 1.0.x (mounts with no plugin version) onto 1.1.0 is carried over by the same
  step on the next boot.
- Command-line LDAP login (`bao login -method=ldap`) is broken upstream in 2.7 (openbao-plugins issue 145);
  documented workaround `bao login -method=userpass -path=<ldap mount>`.
- When a new plugin version is bundled, bump the stanza version; new mounts pick the newest registered
  version, existing tuned mounts keep theirs until tuned.
