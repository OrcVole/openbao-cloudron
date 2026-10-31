# Tag 6.0.1 resolves to this digest (Ubuntu 26.04, glibc 2.43; 6.0.1 is 6.0.0 plus security updates). The final stage must be this exact base.
FROM docker.io/cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee

# Upstream release, pinned in one place. The manifest mirrors it in upstreamVersion.
ARG OPENBAO_VERSION=2.7.2
# SHA-256 of openbao_${OPENBAO_VERSION}_linux_amd64.tar.gz, transcribed from the
# release checksums.txt and pinned here as an independent record.
ARG OPENBAO_SHA256=582b1f3c2fdc5afd443b2d57a225ef654de75adea609fdb66731fd582a9cbc96
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

# The four engines OpenBao 2.7 removed from the main binary (auth/ldap, auth/radius,
# auth/kerberos, secrets/ldap) ship as external plugins from openbao/openbao-plugins.
# Each tarball is signed (detached .sig over the tarball) with the same release key as
# the main binary, and is also pinned by sha256 below, plus the sha256 of the unpacked
# binary, which start.sh writes into the plugin stanzas. Plugins live in a root-owned
# directory the server user cannot write to (the catalog refuses commands outside it).
# One version per plugin: upstream releases them separately, and a security fix can land in one and not the others
# (auth-ldap and auth-radius v0.2.0 carry GHSA-736f-82w7-hj22; kerberos is still v0.1.0).
ARG PLUGIN_AUTH_LDAP_VERSION=v0.2.0
ARG PLUGIN_AUTH_LDAP_SHA256=def2ca548b4a09f0df753ecd19dc8e670a4be4044d57a7c0208528fc340786d8
ARG PLUGIN_AUTH_LDAP_BIN_SHA256=b323b200b2dec50199f36de7dc95a661ce6662da3d53905973c0d7700b4185bb
ARG PLUGIN_AUTH_RADIUS_VERSION=v0.2.0
ARG PLUGIN_AUTH_RADIUS_SHA256=8cc9ea868e0f41e891ca84b76b2b2cc2ca8f6e3315647e2a0a0f8b1853a6d46f
ARG PLUGIN_AUTH_RADIUS_BIN_SHA256=ae2ac43287ed297a9536456b0cbb79c8749a82ffe74a54e3fe886d3285443f07
ARG PLUGIN_AUTH_KERBEROS_VERSION=v0.1.0
ARG PLUGIN_AUTH_KERBEROS_SHA256=1972f00dbfa9bba005beb1286c1ff8902457cd9ce3f21f10fa3acdb15be9ae11
ARG PLUGIN_AUTH_KERBEROS_BIN_SHA256=57ac030fea755adf791600eb2b30aa410d2e848ab7ec7bb54cc515cdce4b89ae
ARG PLUGIN_SECRETS_LDAP_VERSION=v0.1.1
ARG PLUGIN_SECRETS_LDAP_SHA256=d8f5cdf5dd3b5ed72c342473335717dc705fa1c9801b9dcfe4e2cdeece7121f0
ARG PLUGIN_SECRETS_LDAP_BIN_SHA256=4b24d4deec624d76bd8f950dfaf6f59822de14cfb9bd344e2e7c4c492cc77789

# start.sh writes these into the plugin stanzas of zz-managed.hcl.
ENV PLUGIN_AUTH_LDAP_VERSION=${PLUGIN_AUTH_LDAP_VERSION} PLUGIN_AUTH_LDAP_BIN_SHA256=${PLUGIN_AUTH_LDAP_BIN_SHA256} \
    PLUGIN_AUTH_RADIUS_VERSION=${PLUGIN_AUTH_RADIUS_VERSION} PLUGIN_AUTH_RADIUS_BIN_SHA256=${PLUGIN_AUTH_RADIUS_BIN_SHA256} \
    PLUGIN_AUTH_KERBEROS_VERSION=${PLUGIN_AUTH_KERBEROS_VERSION} PLUGIN_AUTH_KERBEROS_BIN_SHA256=${PLUGIN_AUTH_KERBEROS_BIN_SHA256} \
    PLUGIN_SECRETS_LDAP_VERSION=${PLUGIN_SECRETS_LDAP_VERSION} PLUGIN_SECRETS_LDAP_BIN_SHA256=${PLUGIN_SECRETS_LDAP_BIN_SHA256}

RUN set -eu; \
    cd /tmp; \
    export GNUPGHOME=/tmp/gnupg; mkdir -m 0700 "${GNUPGHOME}"; \
    curl -fsSL -o openbao-gpg-pub.asc "https://openbao.org/assets/openbao-gpg-pub-20240618.asc"; \
    gpg --batch --import openbao-gpg-pub.asc; \
    gpg --batch --list-keys --with-colons | grep -q "fpr:::::::::${OPENBAO_GPG_FINGERPRINT}:" \
        || { echo "GPG key fingerprint mismatch"; exit 1; }; \
    install -d -m 0755 -o root -g root /app/code/plugins; \
    fetch_plugin() { \
        name="$1"; ver="$2"; tarsum="$3"; binsum="$4"; \
        file="openbao-plugin-${name}_linux_amd64_v1"; \
        base="https://github.com/openbao/openbao-plugins/releases/download/${name}-${ver}"; \
        curl -fsSL -o "${file}.tar.gz" "${base}/${file}.tar.gz"; \
        curl -fsSL -o "${file}.tar.gz.sig" "${base}/${file}.tar.gz.sig"; \
        curl -fsSL -o "checksums-${name}.txt" "${base}/checksums-${name}.txt"; \
        gpg --batch --status-fd 1 --verify "${file}.tar.gz.sig" "${file}.tar.gz" \
            | grep -q "VALIDSIG .* ${OPENBAO_GPG_FINGERPRINT}\$" \
            || { echo "${name}: signature invalid or wrong key"; exit 1; }; \
        grep " ${file}.tar.gz\$" "checksums-${name}.txt" | sha256sum -c -; \
        echo "${tarsum}  ${file}.tar.gz" | sha256sum -c -; \
        mkdir "x-${name}"; tar -xzf "${file}.tar.gz" -C "x-${name}"; \
        echo "${binsum}  x-${name}/${file}" | sha256sum -c -; \
        install -m 0755 -o root -g root "x-${name}/${file}" "/app/code/plugins/${file}"; \
        install -m 0644 -o root -g root "x-${name}/LICENSE" "/app/code/plugins/LICENSE-plugin-${name}"; \
    }; \
    fetch_plugin auth-ldap "${PLUGIN_AUTH_LDAP_VERSION}" "${PLUGIN_AUTH_LDAP_SHA256}" "${PLUGIN_AUTH_LDAP_BIN_SHA256}"; \
    fetch_plugin auth-radius "${PLUGIN_AUTH_RADIUS_VERSION}" "${PLUGIN_AUTH_RADIUS_SHA256}" "${PLUGIN_AUTH_RADIUS_BIN_SHA256}"; \
    fetch_plugin auth-kerberos "${PLUGIN_AUTH_KERBEROS_VERSION}" "${PLUGIN_AUTH_KERBEROS_SHA256}" "${PLUGIN_AUTH_KERBEROS_BIN_SHA256}"; \
    fetch_plugin secrets-ldap "${PLUGIN_SECRETS_LDAP_VERSION}" "${PLUGIN_SECRETS_LDAP_SHA256}" "${PLUGIN_SECRETS_LDAP_BIN_SHA256}"; \
    rm -rf /tmp/openbao-plugin-* /tmp/x-* /tmp/checksums-*.txt /tmp/openbao-gpg-pub.asc /tmp/gnupg

# Build gate: every plugin binary must run on this base. Executed outside a server a
# go-plugin binary refuses with its handshake message, which proves the file loads
# (glibc, dynamic linking) without needing a host.
RUN set -eu; \
    for f in /app/code/plugins/openbao-plugin-*; do \
        case "$f" in */LICENSE-*) continue;; esac; \
        out="$("$f" 2>&1 || true)"; \
        echo "$out" | grep -q "This binary is a plugin" || { echo "plugin gate: $f did not run: $out"; exit 1; }; \
        echo "plugin gate ok: ${f##*/}"; \
    done; \
    test "$(find /app/code/plugins -name 'openbao-plugin-*' | wc -l)" = 4

# Convenience for cloudron exec shells: the CLI finds the local server.
RUN printf 'export BAO_ADDR=http://127.0.0.1:8200\n' > /etc/profile.d/openbao.sh

COPY start.sh snapshot.sh configure-oidc.sh restore-flag.sh migrate-plugins.sh /app/code/
RUN chmod 0755 /app/code/start.sh /app/code/snapshot.sh /app/code/configure-oidc.sh /app/code/restore-flag.sh /app/code/migrate-plugins.sh

CMD [ "/app/code/start.sh" ]
