# arm64 support plan (target: package 1.1.0)

Why 1.0.0 shipped amd64-only, stated for the record: the package's discipline
is that the shipping digest passes the full gate ladder on a real Cloudron,
and no arm64 Cloudron was available to run it. Upstream publishes arm64
artefacts, so the build is straightforward; the honest gap is validation.

## Build changes

1. Verify `cloudron/base:5.0.0` publishes a linux/arm64 manifest
   (`skopeo inspect --raw docker://cloudron/base:5.0.0` and check the
   manifest list). If it does not, arm64 is off the table for Cloudron
   anyway.
2. Dockerfile: `ARG TARGETARCH`, artefact URL
   `openbao_${OPENBAO_VERSION}_linux_${TARGETARCH}.tar.gz`, and per-arch
   pinned digests (`OPENBAO_SHA256_AMD64`, `OPENBAO_SHA256_ARM64`)
   transcribed from the same GPG-verified `checksums.txt`, selected by
   TARGETARCH. The signature verification flow is unchanged and already
   covers both artefacts.
3. Build and push a manifest list:
   `podman build --platform linux/amd64,linux/arm64 --manifest ...` (or two
   builds plus `podman manifest create/push`). Requires qemu-user-static
   binfmt on the workstation for the arm64 leg.
4. `dockerImage` in the manifest and versions file becomes the manifest
   LIST digest; each box pulls its own architecture.

## Validation tiers (decide before shipping)

- Minimum bar: the full `test/smoke.sh` matrix run against the arm64 image
  under emulation (slow but complete; asserts init, restart auto-unseal,
  snapshot restore, rotation, health matrix).
- Real bar: one full gate-ladder run on a real arm64 Cloudron. Options:
  rent a small arm64 VPS for a day and stand up a throwaway Cloudron, or
  ship with the emulation-tested label and explicitly recruit arm64
  testers in the forum thread before removing the caveat.

## Ship

- Package version 1.1.0, changelog entry, announcement thread follow-up
  post, and remove the "amd64 only" caveat (or soften it to the chosen
  validation label).
