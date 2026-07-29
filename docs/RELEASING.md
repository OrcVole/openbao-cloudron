# Releasing a package version

The order matters: prove the image, then the versions file, then the repo.
Nothing goes public before the secret scan and the operator's go.

1. **Bump** the upstream `ARG OPENBAO_VERSION` and `OPENBAO_SHA256` in the
   Dockerfile (transcribe the digest from the release `checksums.txt`), the
   manifest `version` and `upstreamVersion`, and add a bracket-format
   `[x.y.z]` entry to `CHANGELOG.md`.
2. **Build and smoke**: `podman build -t openbao-cloudron:dev .` then
   `test/smoke.sh openbao-cloudron:dev`. All assertions must pass.
3. **Push**: tag as `ghcr.io/orcvole/openbao-cloudron:<version>`, push, and
   read the registry digest with
   `skopeo inspect --format '{{.Digest}}' docker://ghcr.io/orcvole/openbao-cloudron:<version>`
   (the local digest differs; only the registry one counts).
4. **Gate ladder** on a throwaway install by that digest. A rebuilt image
   restarts the ladder. Update `docs/DEBUGGING.md` evidence tables.
5. **Pin** the digest as `dockerImage` in `CloudronManifest.json`.
6. **CloudronVersions.json**: regenerate (hand-construction is the reliable
   path on this workstation; `cloudron versions add` needs a Docker socket
   the podman bridge does not satisfy). Every entry needs all four of
   `manifest` (with `file://` fields inlined and `dockerImage` set to the
   digest), `creationDate` (ISO-8601), `ts` (Unix milliseconds, a number)
   and `publishState` ("published"). Pre-flight:
   `jq '.versions|to_entries[]|select((.value.ts|type)!="number" or (.value.creationDate==null) or (.value.publishState==null))|.key' CloudronVersions.json`
   must print nothing.
7. **Secret scan**: `test/secret-scan.sh` clean (sha256 digest pins are the
   only expected hits).
8. **Publish**: push to the private mirror first, then GitHub. First release
   only: flip the GHCR package public (web UI, package settings, Danger
   Zone) and prove an anonymous `podman pull` by digest succeeds while
   logged out.
9. **Stranger gate**: `cloudron install --versions-url <raw
   CloudronVersions.json URL> --location <throwaway>` must pull the digest
   ("Using image ... (from versions url)"), come up healthy and show the
   icon. Note `raw.githubusercontent.com` serves stale content for a few
   minutes after a push; verify via the GitHub contents API before blaming
   the file.
10. **Remember**: anything added to the published versions file
    auto-deploys to every existing install. Never publish an untested
    entry.
