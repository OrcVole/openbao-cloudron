OpenBao is an open source identity-based secrets and encryption management
system, a community-driven fork of HashiCorp Vault stewarded by the Linux
Foundation under the OpenSSF. It provides a central, audited place to store,
generate and control access to secrets: API keys, passwords, certificates and
encryption keys, with a web UI, a CLI and a Vault-compatible HTTP API.

This package is built for unattended operation on Cloudron:

* **Auto-unseal by default.** The package configures OpenBao's built-in static
  key seal, so the instance comes back serving secrets after every restart and
  automatic update with no human intervention. (Self-hosted Vault and OpenBao
  installations normally require an operator to paste unseal key shares after
  every restart.)
* **Initialised out of the box.** On first start the package initialises
  OpenBao, enables the KV v2 secrets engine and a file audit device, and leaves
  the root token and recovery keys for you in `/app/data/.secrets`.
* **Consistent backups.** Integrated raft storage is snapshotted hourly with
  OpenBao's own snapshot mechanism, and the snapshots ride Cloudron backups.
  Restores and clones rebuild the store from the newest snapshot automatically.
* **Honest health reporting.** A sealed instance reports unhealthy to Cloudron
  instead of pretending all is well.
* **Cloudron sign-on and app integration.** Cloudron accounts can log in to
  the UI via OIDC (with no access to secrets until granted), and other apps
  consume the Vault-compatible API with AppRole credentials.

The convenience of auto-unseal has a stated cost: the unseal key lives on the
same server as the data it protects. Read the post-install notes for the threat
model and the hardening steps (off-server copies of the recovery material and
encrypted Cloudron backups). A manual-unseal (Shamir) mode is available for
operators who prefer it.

This is an unofficial community package. It is not affiliated with or endorsed
by the OpenBao project, the Linux Foundation, or Cloudron. OpenBao is
distributed unmodified under the Mozilla Public License 2.0; source code is at
https://github.com/openbao/openbao.
