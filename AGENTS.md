# Working contract for this repository

Settled decisions. Do not relitigate them in later sessions; change them only
with an ADR that supersedes the existing one.

1. **Thin adaptation layer.** The upstream OpenBao release binary ships
   unmodified. The package adapts its runtime to Cloudron's contract and does
   nothing else. Upstream version is pinned in exactly one place (the
   Dockerfile `ARG`); the manifest mirrors it in `upstreamVersion`.
2. **The point of the package is unattended operation.** Auto-unseal by
   default, automatic initialisation, snapshot-based backups that restore
   without ceremony. Anything that reintroduces a mandatory human step after
   a restart needs a very good reason and an ADR.
3. **Fail loud, never silently.** A boot path that cannot reach a safe state
   exits non-zero with a clear `==>` message. No silent fallbacks that leave
   the operator believing something worked.
4. **Persistent state only in `/app/data` and `/app/openbao`.** The raft
   store lives on the persistentDir and is excluded from backups by design;
   snapshots in `/app/data` are the restore artefact. Do not move the store
   back into the file-walked backup.
5. **Secrets discipline.** Generated credentials live in
   `/app/data/.secrets`, 0600, cloudron:cloudron, re-asserted every boot.
   Never log a key, token or recovery share; log presence, paths and digests
   only. This applies to test output and documentation too: record SHA-256
   prefixes, never values.
6. **Config split.** `main.hcl` belongs to the operator (generated once,
   never rewritten). `zz-managed.hcl` belongs to the package (regenerated
   every boot). Package-forced settings go only in the managed file.
7. **House style.** British spelling, no em dashes, no contractions in
   repository prose. Commits are authored by the packager identity with no
   AI attribution trailers of any kind.
8. **Public-repo anonymity.** Nothing host-specific in any tracked file: no
   real hostnames, no server inventory, no personal emails, no tokens.
   `test/secret-scan.sh` is a release gate, run before every push.
9. **Empirical verification beats documentation.** Behaviour claimed in docs
   (including this repo's own) is verified against a running instance before
   being relied on. `docs/PACKAGING-NOTES.md` records what was verified
   versus assumed; `docs/DEBUGGING.md` records gate evidence.
10. **Upstream contributions are hand-written.** OpenBao's CONTRIBUTING.md
    forbids generative AI assistance for code and PR/issue text in their
    repositories. Anything destined for an OpenBao repository is written by
    a human, full stop. This packaging repository is not theirs and is not
    covered; the boundary is flagged whenever it comes up.
