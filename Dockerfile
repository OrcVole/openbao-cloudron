FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

# Upstream release, pinned in one place. The manifest mirrors it in upstreamVersion.
ARG OPENBAO_VERSION=2.6.1
# SHA-256 of openbao_${OPENBAO_VERSION}_linux_amd64.tar.gz, transcribed from the
# release checksums.txt and pinned here as an independent record.
ARG OPENBAO_SHA256=ca8d836eb3a5c80407e45e762300b64e7138c419e78826955f2e4ba4ce6d8a6b
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

COPY start.sh snapshot.sh configure-oidc.sh /app/code/
RUN chmod 0755 /app/code/start.sh /app/code/snapshot.sh /app/code/configure-oidc.sh

CMD [ "/app/code/start.sh" ]
