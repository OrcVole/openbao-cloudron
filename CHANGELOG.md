[1.1.0]

- OpenBao 2.6.4 to 2.7.1. **Why now:** upstream support for the 2.6 line is ending. This is not a security
  catch-up: 2.6.4 already carried the fixes of 2.7.0 and 2.7.1 (the same fifteen advisories).
- **LDAP, RADIUS and Kerberos auth and the LDAP secrets engine are now bundled plugins.** OpenBao 2.7
  removed these four engines from the main program. This package ships all four as the upstream
  `openbao-plugins` v0.1.0 releases (`auth-ldap`, `auth-radius`, `auth-kerberos`, `secrets-ldap`), each
  verified at build time against OpenBao's release signing key and a pinned checksum, installed in a
  read-only directory and registered on every start. They are first releases (v0.1.0).
- **Existing mounts carry over.** If your install already has an LDAP, RADIUS or Kerberos auth mount, or an
  LDAP secrets mount, it is switched to the bundled plugin automatically on the first start after this
  update (the log says `[plugins] ... now runs plugin v0.1.0`). Its configuration, users, group mappings,
  policies and entity ids are untouched; the same users sign in with the same policies. The step needs the
  stored root token (`/app/data/.secrets/root-token`); if you deleted it, the log says so, and you run
  `bao auth tune -plugin-version=v0.1.0 <mount>/` (or `bao secrets tune ...` for the LDAP secrets engine)
  yourself with any token allowed to tune the mount. A mount that shows in `bao auth list` but fails every
  request after an update is this case.
- **Command line: LDAP login.** The 2.7 `bao` client no longer has the `ldap` login method (upstream
  openbao-plugins issue 145, open at the time of writing), so `bao login -method=ldap` fails, on the
  `bao` in this app and on your own machine if it is 2.7. Workaround, same result:
  `bao login -method=userpass -path=<your ldap mount>` (for example `-path=ldap`), and enter your LDAP
  username and password. The web UI and the API (`/v1/auth/<mount>/login/<user>`) are unaffected.
- PKI: a certificate name ending in a trailing dot (`example.com.`) is no longer accepted by the PKI engine
  (upstream 2.7.0). The package does not enable PKI; this only matters if you did.
- Config: the package now sets `plugin_directory` and `plugin_auto_register` in its managed config file.
  Do not set `plugin_directory` in `main.hcl`.
- Base image cloudron/base 6.0.0 to 6.0.1: Ubuntu security updates, including the removal of the
  compromised eMudhra emSign ECC Root CA - G3 from the trusted certificates.

[1.0.4]

- OpenBao 2.6.3 to 2.6.4, a security update. The 2.6.4 notes list five advisories (six fixes), all in GH-4148:
  disclosure of `tls_acme_eab_mac_key` from `sys/config/state/sanitized` (GHSA-3237-j65r-m5rp); the
  unauthenticated Root Token Generation and Rekey endpoints, disabled by default, returning their response
  even when audit logging failed (GHSA-q74w-hv5x-6hxf); an AppRole Secret ID usable after expiry but before
  tidy (GHSA-7m59-mp95-w6ph); AppRole login with form-data bodies decoded on the wrong path, and a TLS
  connection not propagated into the cert auth role quota (both GHSA-5v22-543h-wg96); and a Kubernetes auth
  Service Account JWT not validated on renewal (GHSA-gf3j-hm38-jhh5).
- **Why this update is 2.6.4 and not 2.7.** OpenBao 2.7 removes LDAP, RADIUS and Kerberos auth and the
  LDAP secrets engine from the main program; they continue as separate plugins (openbao-plugins, first
  released 2026-10-02). Taking 2.7 now would break any install that uses one of them:
  - an existing LDAP, RADIUS or Kerberos auth mount, or LDAP secrets mount, would not start until the
    matching plugin is installed and registered under the same name, and that path is not yet proven;
  - the 2.7 `bao` command-line client also dropped its LDAP login method, so `bao login -method=ldap`
    stops working on users' own machines (upstream openbao-plugins issue #145; the workaround is
    `bao login -method=userpass -path=<your ldap mount>`);
  - the plugins are at their first release (v0.1.0).
  2.6.4 carries the same security fixes, so nothing is lost by waiting. A later package release will move
  to 2.7 with the four plugins bundled, tested by carrying a real LDAP mount across the upgrade, and will
  say so here first.
- Base image cloudron/base 5.1.0 to 6.0.0 (Ubuntu 26.04, glibc 2.43).
- **Fix: restoring a backup now actually restores your secrets.** Until this release an in-place restore
  (Restore on an existing app) brought back the backup's settings but kept the CURRENT secrets store,
  because that store lives in a persistent directory the platform does not roll back. Every earlier
  release has this defect; restoring to a new app (a clone) was never affected. Now a restore moves the
  current store aside to `/app/openbao/quarantine-<time>` (kept for 30 days, so nothing is lost) and
  rebuilds from the snapshot the backup carries. With the Shamir seal an automatic rebuild is not
  possible: the app keeps the current store and says so in its log.

[1.0.3]

- OpenBao 2.6.3, a security release. It fixes nine advisories published on 2026-09-23. The most serious
  is a CRITICAL remote code execution through raft snapshot restore replacing the plugin catalog
  (GHSA-j6wc-jpvg-xfxq); this package uses raft storage, so it applies here, although it needs a highly
  privileged token. Also fixed: an ACL bypass via non-canonical URLs (GHSA-fg5x-7whg-6c28, HIGH), a
  cross-namespace policy cache traversal (GHSA-mjch-vcw3-hhmf, HIGH), unvalidated SANs through PKI ACME
  (GHSA-x8fg-h69x-p28f, HIGH), an open redirect in the OIDC provider UI (GHSA-2cjw-94fw-wqjx), and four
  low-severity issues. Updating is recommended.
- Upstream bug fixes include snapshot restore, recovery token generation and namespace listing in
  recovery mode.
- Base image cloudron/base 5.0.0 to 5.1.0: the Ubuntu 24.04.4 point release, with its OS security
  updates. Same Ubuntu 24.04 release and glibc 2.39.

[1.0.2]

- OpenBao 2.6.2, a security release: internal operation types can no longer be dispatched from inline authentication or workflows to create tokens (GHSA-rh46-vc3j-w2w3), and the PKI secrets engine now enforces `allowed_ip_sans_cidr` on IP SANs taken from CSRs (GHSA-g892-p242-8g86)
- Upstream fixes that matter on this package: OIDC `default` keys are written to per-namespace storage, a panic in the request handler between initialisation and active enablement is prevented, and `enable_rate_limit_audit_logging` works again

[1.0.1]

- Fix: the boot-time OIDC re-provisioning no longer resets the `cloudron` role's token_policies/token_ttl/token_max_ttl — operator-granted policies now survive restarts and updates

[1.0.0]

- Initial release
- OpenBao 2.6.1, integrated raft storage, web UI enabled
- Auto-unseal by default via the built-in static key seal; Shamir mode available as an opt-in
- Zero-touch first start: automatic initialisation, KV v2 mounted at secret/, file audit device enabled
- Hourly raft snapshots into /app/data/snapshots ride Cloudron backups, plus a fresh snapshot at backup time; automatic restore from the newest snapshot on restore or clone
- Health check reports a sealed instance as unhealthy
- Cloudron single sign-on for the UI (optional): Cloudron accounts log in via OIDC with no secret access until granted; AppRole integration recipes for other apps
