# Tag 6.0.0 resolves to this digest (Ubuntu 26.04, glibc 2.43). The final stage must be this exact base.
FROM docker.io/cloudron/base:6.0.0@sha256:9bed4c8fa880645f8e669041ee28febe941481d00e9445e3e5a5483cb541d09b

# Upstream release, pinned in one place. The manifest mirrors it in upstreamVersion.
ARG OPENBAO_VERSION=2.6.4
# SHA-256 of openbao_${OPENBAO_VERSION}_linux_amd64.tar.gz, transcribed from the
# release checksums.txt and pinned here as an independent record.
ARG OPENBAO_SHA256=659a4875cb197d042b2c612e7b0e275f36ebacc16e3f1f6e8dc31275f6d84220
# Primary fingerprint of the OpenBao release signing key (openbao.org/docs/install/).
ARG OPENBAO_GPG_FINGERPRINT=66D15FDD87287219C8E15478D200CD702853E6D0

ENV OPENBAO_VERSION=${OPENBAO_VERSION}

RUN mkdir -p /app/code /app/openbao
WORKDIR /app/code

# Fetch the release tarball plus the signed checksum manifest, verify the GPG
# signature against the pinned fingerprint, verify the tarball against the signed
# checksums, and independently against the digest pinned above. Two belts, on
# purpose: the signature proves the release chain, the pinned digest is a record
# in our own history that survives an upstream key rotation.
RUN set -eu; \
    cd /tmp; \
    base="https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}"; \
    curl -fsSL -o bao.tgz "${base}/openbao_${OPENBAO_VERSION}_linux_amd64.tar.gz"; \
    curl -fsSL -o checksums.txt "${base}/checksums.txt"; \
    curl -fsSL -o checksums.txt.gpgsig "${base}/checksums.txt.gpgsig"; \
    curl -fsSL -o openbao-gpg-pub.asc "https://openbao.org/assets/openbao-gpg-pub-20240618.asc"; \
    export GNUPGHOME=/tmp/gnupg; mkdir -m 0700 "${GNUPGHOME}"; \
    gpg --batch --import openbao-gpg-pub.asc; \
    gpg --batch --list-keys --with-colons | grep -q "fpr:::::::::${OPENBAO_GPG_FINGERPRINT}:" \
        || { echo "GPG key fingerprint mismatch"; exit 1; }; \
    gpg --batch --status-fd 1 --verify checksums.txt.gpgsig checksums.txt \
        | grep -q "VALIDSIG ${OPENBAO_GPG_FINGERPRINT}\|VALIDSIG .* ${OPENBAO_GPG_FINGERPRINT}" \
        || { echo "checksums.txt signature invalid or wrong key"; exit 1; }; \
    grep " openbao_${OPENBAO_VERSION}_linux_amd64.tar.gz\$" checksums.txt > sum.txt; \
    sed 's| openbao_.*| bao.tgz|' sum.txt | sha256sum -c -; \
    echo "${OPENBAO_SHA256}  bao.tgz" | sha256sum -c -; \
    tar -xzf bao.tgz -C /app/code bao LICENSE CHANGELOG.md; \
    mv /app/code/LICENSE /app/code/LICENSE-openbao; \
    mv /app/code/CHANGELOG.md /app/code/CHANGELOG-openbao.md; \
    chmod 0755 /app/code/bao; \
    ln -s /app/code/bao /usr/local/bin/bao; \
    rm -rf /tmp/bao.tgz /tmp/checksums.txt* /tmp/openbao-gpg-pub.asc /tmp/gnupg /tmp/sum.txt

# Build gate: the binary must run on this base.
RUN /app/code/bao version

# Convenience for cloudron exec shells: the CLI finds the local server.
RUN printf 'export BAO_ADDR=http://127.0.0.1:8200\n' > /etc/profile.d/openbao.sh

COPY start.sh snapshot.sh configure-oidc.sh restore-flag.sh /app/code/
RUN chmod 0755 /app/code/start.sh /app/code/snapshot.sh /app/code/configure-oidc.sh /app/code/restore-flag.sh

CMD [ "/app/code/start.sh" ]
