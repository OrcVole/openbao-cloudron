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
