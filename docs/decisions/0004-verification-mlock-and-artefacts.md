# ADR 0004: Release artefact verification; no mlock anywhere

Status: accepted (2026-07-29)

## Artefact verification

The Dockerfile downloads the upstream release tarball and verifies it two
ways, on purpose:

1. GPG: `checksums.txt.gpgsig` is verified against the OpenBao release key,
   whose primary fingerprint is pinned in the Dockerfile
   (`66D1 5FDD 8728 7219 C8E1 5478 D200 CD70 2853 E6D0`), then the tarball
   is checked against the signed checksums. This proves the release chain.
2. A SHA-256 of the tarball, transcribed once and pinned as a build ARG,
   independently checked. This is a reviewable record in our own history
   that survives an upstream key rotation and catches a transcription-level
   mismatch between what we audited and what a rebuild downloads.

`LICENSE` and upstream's changelog are taken from inside the verified
tarball (MPL-2.0 section 3.2 obligations: licence copy shipped in-image as
`/app/code/LICENSE-openbao`; source availability stated in `NOTICE`).

## mlock

OpenBao removed mlock support entirely in the 2.x line (the mmap'd raft
store made `mlockall` actively harmful). `disable_mlock = false` in a config
is a fatal startup error; the option is otherwise ignored. Therefore, and
deliberately, this package has: no `capabilities: ["mlock"]` in the
manifest, no `setcap cap_ipc_lock` in the Dockerfile, no `libcap2-bin`
install, and no `disable_mlock` line in any generated config. All four are
copied by habit from Vault-era templates and the config line would prevent
the server from booting.

The residual risk mlock used to cover (secrets paged to unencrypted swap)
is a host property now; README's security section carries upstream's
guidance (encrypt or disable swap at host level).
