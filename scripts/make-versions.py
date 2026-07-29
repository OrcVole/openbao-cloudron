#!/usr/bin/env python3
"""Generate CloudronVersions.json for the community versions-url channel.

Usage: scripts/make-versions.py ghcr.io/orcvole/openbao-cloudron@sha256:<digest>

Reads CloudronManifest.json from the repo root, inlines the file:// content
fields (a versions-url install fetches only this JSON, never the repo), pins
dockerImage to the given registry digest, and writes/updates the version
entry with the four fields the validator requires: manifest, creationDate
(ISO-8601), ts (Unix milliseconds, as a number) and publishState. Existing
entries for other versions are preserved.

The validator's error messages can mislead ("invalid ts" for a missing
publishState); the pre-flight check in docs/RELEASING.md is the cure.
"""
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    if len(sys.argv) != 2 or "@sha256:" not in sys.argv[1]:
        print(__doc__)
        return 2
    docker_image = sys.argv[1]

    manifest = json.loads((ROOT / "CloudronManifest.json").read_text())
    for field in ("description", "changelog", "postInstallMessage"):
        value = manifest.get(field, "")
        if isinstance(value, str) and value.startswith("file://"):
            manifest[field] = (ROOT / value[len("file://"):]).read_text()
    manifest["dockerImage"] = docker_image

    version = manifest["version"]
    out_path = ROOT / "CloudronVersions.json"
    doc = {"stable": True, "versions": {}}
    if out_path.exists():
        doc = json.loads(out_path.read_text())
        doc.setdefault("versions", {})

    now_ms = int(time.time() * 1000)
    doc["versions"][version] = {
        "manifest": manifest,
        "creationDate": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "ts": now_ms,
        "publishState": "published",
    }
    doc["stable"] = True

    out_path.write_text(json.dumps(doc, indent=4, ensure_ascii=False) + "\n")

    bad = [
        v for v, e in doc["versions"].items()
        if not isinstance(e.get("ts"), int)
        or not e.get("creationDate")
        or not e.get("publishState")
        or not e.get("manifest", {}).get("packagerName")
        or not e.get("manifest", {}).get("iconUrl")
        or not e.get("manifest", {}).get("contactEmail")
    ]
    if bad:
        print(f"PRE-FLIGHT FAIL: entries missing required fields: {bad}")
        return 1
    print(f"wrote {out_path.name}: version {version} -> {docker_image[:60]}...")
    print("pre-flight: all entries carry ts(number)/creationDate/publishState/packagerName/iconUrl/contactEmail")
    return 0


if __name__ == "__main__":
    sys.exit(main())
