[1.0.0]
* Initial release
* OpenBao 2.6.1, integrated raft storage, web UI enabled
* Auto-unseal by default via the built-in static key seal; Shamir mode available as an opt-in
* Zero-touch first start: automatic initialisation, KV v2 mounted at secret/, file audit device enabled
* Hourly raft snapshots into /app/data/snapshots ride Cloudron backups, plus a fresh snapshot at backup time; automatic restore from the newest snapshot on restore or clone
* Health check reports a sealed instance as unhealthy
* Cloudron single sign-on for the UI (optional): Cloudron accounts log in via OIDC with no secret access until granted; AppRole integration recipes for other apps
