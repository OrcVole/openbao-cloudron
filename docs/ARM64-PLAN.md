# arm64: not applicable (finding, 2026-07-29)

Investigated whether the package should ship an arm64 build. It should not,
and cannot usefully, because **Cloudron itself does not run on ARM**. This
is a platform constraint, not a packaging gap, and it closes the question
until Cloudron's own position changes.

## Evidence

- Cloudron's installation documentation states plainly: "Cloudron does not
  support ARM, LXC, Docker, or OpenVZ", and requires a fresh Ubuntu 24.04
  **x64** server.
- `cloudron/base:5.0.0` publishes a **single-architecture** manifest,
  `linux/amd64`. There is no platform list to select from, and no
  arm-suffixed tag in the repository. Since Cloudron requires the final
  image stage to be built from `cloudron/base` (the dashboard's file
  manager, web terminal and log viewer depend on its userland), an arm64
  final stage is not available at all.
- Community requests for ARM exist on the Cloudron forum (Raspberry Pi and
  Ampere cloud-server threads). The maintainers' stated position is that every
  package would need repackaging and binaries rebuilt and tested per
  update, so it needs strong demand to justify. A `base-arm64` image
  exists but has not been updated in about two years.

## What is not the blocker

Upstream OpenBao is ready: the 2.6.1 release publishes
`openbao_2.6.1_linux_arm64.tar.gz` alongside amd64, in the same GPG-signed
`checksums.txt` (arm64 digest
`a74aa73b80000a4340a90edbf27726c0fb0a4537970eab6e1a7e0e211d117b75`). If the
platform ever supports ARM, the package change is small and mechanical:

1. `ARG TARGETARCH` in the Dockerfile; artefact URL becomes
   `openbao_${OPENBAO_VERSION}_linux_${TARGETARCH}.tar.gz`.
2. Per-architecture pinned digests selected by `TARGETARCH`; the existing
   GPG verification of `checksums.txt` already covers both artefacts.
3. Build both legs and push a manifest list; pin the list digest in the
   manifest and versions file so each box pulls its own architecture.
4. Run the full smoke matrix on the arm64 image, then a gate-ladder run on
   a real arm64 Cloudron, which is the step that does not exist today.

## Recommendation

Say "amd64 only, because Cloudron is amd64 only" in the package
documentation rather than implying an arm64 build is pending work on our
side. Revisit only if Cloudron announces ARM support.
