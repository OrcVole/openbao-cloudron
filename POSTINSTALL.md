**OpenBao is running, initialised and unsealed.** No setup steps are required
before you can use it.

#### First things first

1. Open the File Manager (or Web Terminal) and copy everything in
   `/app/data/.secrets` to a safe place **outside this server**: `root-token`
   (log in with this), `init.json` (recovery key shares), and `unseal.key`
   (the auto-unseal key). If this server is lost, these are what make your
   backups readable.
2. Log in to the web UI with the root token (method **Token**), then create
   your own admin sign-in under Access, for example **userpass**, and use that
   day to day instead of the root token.
3. In Cloudron, enable backup encryption (Settings, then Backups) if you have
   not already. App backups contain the auto-unseal key next to the data it
   decrypts; encrypting backups closes that gap at rest.

#### How this package keeps your data safe

A raft snapshot is taken every hour (and before each backup when possible)
into `/app/data/snapshots`, and that is what Cloudron backs up. After a
restore or clone, the app rebuilds itself from the newest snapshot
automatically. Changes made after the last snapshot are not in the backup;
take a manual snapshot before risky changes, in this app's Web Terminal:

```
bao operator raft snapshot save /app/data/snapshots/raft-manual.snap
```

(Requires a token; `export BAO_TOKEN=$(cat /app/data/.secrets/root-token)`.)

#### The auto-unseal trade-off, stated plainly

The unseal key lives at `/app/data/.secrets/unseal.key`, on the same server as
the data. This protects a stolen disk or backup only if the backup itself is
encrypted, and it does not protect against anyone with root on this server or
admin on this Cloudron. OpenBao's own documentation recommends a static seal
"when an existing source of trust already exists in the operating
environment"; on Cloudron, that source of trust is the server itself, and the
alternative is manually unsealing after every restart and update. If you
prefer that, the README documents the Shamir mode and the migration procedure
in both directions.

#### Cloudron sign-in (reference)

<sso>Cloudron users can sign in from the UI's **OIDC** option. They get no
access to any secret until you grant policies (Access, then Authentication
methods, or see the package's INTEGRATIONS documentation). Other apps should
use AppRole credentials, never the root token.</sso>

#### Useful facts (reference, not setup)

* CLI from your own machine: `export BAO_ADDR=https://$CLOUDRON-APP-FQDN` then
  `bao login` (the `bao` CLI is a single binary from openbao.org; the `vault`
  CLI also works against it).
* The API is Vault-compatible at `https://$CLOUDRON-APP-FQDN/v1/...`.
* Audit log: `/app/data/audit/audit.log` (rotated automatically at 64 MB).
* A KV v2 secrets engine is mounted at `secret/`.
* Operator configuration lives in `/app/data/config/main.hcl`; the seal and
  listener are package-managed in `zz-managed.hcl` and regenerate on restart.
