#!/bin/bash
# Anonymity and secret sweep over the tracked file set. Release gate: run
# before every push. Exit non-zero on any hit.
#
# Box- and session-specific strings (real hostnames, usernames, addresses)
# live in a GITIGNORED denylist file, .anonymize-list, one fixed string per
# line (case-insensitive substring match). This script keeps only generic
# secret SHAPES inline, so the scanner itself never leaks what it hunts.
set -uo pipefail
cd "$(dirname "$0")/.."

HITS=0

files() {
    if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        git ls-files
    else
        find . -type f -not -path './.git/*' | sed 's|^\./||'
    fi
}

scan() { # scan <label> <grep-args...>
    local label="$1"; shift
    local out
    out=$(files | xargs -r grep -I -n "$@" 2>/dev/null | grep -v '^test/secret-scan.sh:' || true)
    if [[ -n "${out}" ]]; then
        echo "== ${label} =="
        echo "${out}"
        HITS=$((HITS + $(wc -l <<< "${out}")))
    fi
}

# Generic secret shapes.
scan "private key material"      -E -- '-----BEGIN [A-Z ]*PRIVATE KEY-----'
scan "GitHub token"              -E -- 'gh[pousr]_[A-Za-z0-9]{20,}'
scan "Vault/OpenBao token shape" -E -- '\b(hvs|hvb|s)\.[A-Za-z0-9]{24,}'
scan "AWS access key id"         -E -- '\bAKIA[0-9A-Z]{16}\b'
scan "generic bearer secret"     -E -- '(api[_-]?key|secret|token|password)["'"'"']?\s*[:=]\s*["'"'"'][A-Za-z0-9+/_-]{20,}'
scan "long hex blob (64+)"       -E -- '\b[0-9a-f]{64}\b'

# 64-hex exception: pinned artefact digests are expected in these files.
if [[ ${HITS} -gt 0 ]]; then
    : # counted above; digests in Dockerfile/manifest/versions will show here and
      # must be eyeballed: sha256 pins are fine, anything else is not.
fi

# Personal / host-specific strings from the gitignored denylist.
if [[ -f .anonymize-list ]]; then
    count=0
    while IFS= read -r needle; do
        [[ -z "${needle}" || "${needle}" =~ ^# ]] && continue
        out=$(files | xargs -r grep -I -i -n -F -- "${needle}" 2>/dev/null || true)
        if [[ -n "${out}" ]]; then
            echo "== denylist match: entry $((++count)) (value withheld) =="
            echo "${out}" | cut -d: -f1,2
            HITS=$((HITS + $(wc -l <<< "${out}")))
        fi
    done < .anonymize-list
else
    echo "NOTE: .anonymize-list not found; host-specific sweep skipped." >&2
fi

echo
if [[ ${HITS} -gt 0 ]]; then
    echo "secret-scan: ${HITS} finding(s). Review every line; sha256 digest pins are the only expected hits."
    exit 1
fi
echo "secret-scan: clean."
