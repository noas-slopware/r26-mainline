#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Plan, merge and fetch the [gustard-r26] apk repository on the Pages site.

  repo.py plan  --alpine DIR --site URL [--force]
      Hash every package directory of the alpine branch (its files, the Alpine version and
      tools/abuild-docker.sh) and compare with built.json of the published repository. Prints
      GitHub step outputs: build (JSON list of package directories to build, in build order),
      reuse (JSON list of published files to keep), any (true when something is to be built).
  repo.py merge --alpine DIR --site URL --new DIR --out DIR
      Fill <out> with the published files of every package that was not rebuilt and the new
      packages from <new>, drop everything else, and write built.json (origin -> hash, version,
      files). Indexing and signing happen afterwards, in the Alpine container.
  repo.py fetch URL DIR
      Download the live repository (as listed by its packages.txt) into DIR/<REPO_PATH>, for the
      mirror job when this run deployed nothing.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

ALPINE = os.environ.get("ALPINE_VERSION", "3.24")
REPO_PATH = f"alpine/v{ALPINE}/gustard-r26/armv7"
# build order: a package's build may install the ones before it (abuild -r builddeps)
ORDER = ["linux-gustard-r26", "raat-endpoint", "device-gustard-r26"]


def get(url: str) -> bytes | None:
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def pkg_hash(alpine: str, name: str) -> str:
    h = hashlib.sha256()
    h.update(f"alpine {ALPINE}\n".encode())
    with open(os.path.join(alpine, "tools", "abuild-docker.sh"), "rb") as f:
        h.update(f.read())
    top = os.path.join(alpine, name)
    for root, dirs, files in os.walk(top):
        dirs.sort()
        for fn in sorted(files):
            p = os.path.join(root, fn)
            h.update(os.path.relpath(p, top).encode() + b"\0")
            with open(p, "rb") as f:
                h.update(f.read())
    return h.hexdigest()


def apkbuild_version(alpine: str, name: str) -> str:
    text = open(os.path.join(alpine, name, "APKBUILD")).read()
    ver = re.search(r"^pkgver=(\S+)", text, re.M).group(1)
    rel = re.search(r"^pkgrel=(\S+)", text, re.M).group(1)
    return f"{ver}-r{rel}"


def packages(alpine: str) -> list[str]:
    found = sorted(d for d in os.listdir(alpine) if os.path.isfile(os.path.join(alpine, d, "APKBUILD")))
    unknown = set(found) - set(ORDER)
    if unknown:
        sys.exit(f"no build order for {sorted(unknown)}: add them to ORDER")
    return [p for p in ORDER if p in found]


def published(site: str) -> dict:
    raw = get(f"{site}/{REPO_PATH}/built.json")
    return json.loads(raw) if raw else {}


def origin_of(apk: str) -> tuple[str, str]:
    info = subprocess.run(["tar", "-xzOf", apk, ".PKGINFO"], capture_output=True, check=True).stdout.decode()
    f = dict(l.split(" = ", 1) for l in info.splitlines() if " = " in l)
    return f.get("origin", f["pkgname"]), f["pkgver"]


def cmd_plan(a) -> None:
    pub = published(a.site)
    build, reuse = [], []
    for p in packages(a.alpine):
        h = pkg_hash(a.alpine, p)
        old = pub.get(p)
        if not a.force and old and old.get("hash") == h:
            reuse += old["files"]
            print(f"{p}: published build is current ({old['version']})", file=sys.stderr)
        else:
            build.append(p)
            print(f"{p}: build ({apkbuild_version(a.alpine, p)})", file=sys.stderr)
    out = os.environ.get("GITHUB_OUTPUT")
    lines = [f"build={json.dumps(build)}", f"reuse={json.dumps(reuse)}",
             f"any={'true' if build else 'false'}"]
    if out:
        with open(out, "a") as f:
            f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


def cmd_merge(a) -> None:
    pub = published(a.site)
    os.makedirs(a.out, exist_ok=True)
    built = {}
    new = {}
    for fn in sorted(os.listdir(a.new)):
        if fn.endswith(".apk"):
            o, v = origin_of(os.path.join(a.new, fn))
            new.setdefault(o, {"version": v, "files": []})["files"].append(fn)
    for p in packages(a.alpine):
        h = pkg_hash(a.alpine, p)
        if p in new:
            for fn in new[p]["files"]:
                shutil.copy2(os.path.join(a.new, fn), os.path.join(a.out, fn))
            built[p] = {"hash": h, "version": apkbuild_version(a.alpine, p), "files": new[p]["files"]}
        elif p in pub and pub[p].get("hash") == h:
            for fn in pub[p]["files"]:
                data = get(f"{a.site}/{REPO_PATH}/{fn}")
                if data is None:
                    sys.exit(f"{fn} is listed in the published built.json but not served")
                with open(os.path.join(a.out, fn), "wb") as f:
                    f.write(data)
            built[p] = pub[p]
        else:
            sys.exit(f"{p}: neither built in this run nor published at its current hash")
    with open(os.path.join(a.out, "built.json"), "w") as f:
        json.dump(built, f, indent=1, sort_keys=True)
        f.write("\n")
    files = sorted(fn for b in built.values() for fn in b["files"])
    with open(os.path.join(a.out, "packages.txt"), "w") as f:
        f.write("".join(fn + "\n" for fn in files))
    print(json.dumps(built, indent=1, sort_keys=True))


def cmd_fetch(a) -> None:
    listing = get(f"{a.url}/{REPO_PATH}/packages.txt")
    if listing is None:
        print("nothing published yet")
        return
    dest = os.path.join(a.dir, REPO_PATH)
    os.makedirs(dest, exist_ok=True)
    names = listing.decode().split() + ["APKINDEX.tar.gz", "built.json", "packages.txt"]
    for fn in names:
        data = get(f"{a.url}/{REPO_PATH}/{fn}")
        if data is None:
            sys.exit(f"{fn} is not served")
        with open(os.path.join(dest, fn), "wb") as f:
            f.write(data)
    for fn in ("r26-mainline-1cc0db58.rsa.pub",):
        data = get(f"{a.url}/alpine/{fn}")
        if data is not None:
            with open(os.path.join(a.dir, "alpine", fn), "wb") as f:
                f.write(data)
    print(f"{len(names)} files")


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--alpine", required=True)
    p.add_argument("--site", required=True)
    p.add_argument("--force", action="store_true")
    m = sub.add_parser("merge")
    m.add_argument("--alpine", required=True)
    m.add_argument("--site", required=True)
    m.add_argument("--new", required=True)
    m.add_argument("--out", required=True)
    f = sub.add_parser("fetch")
    f.add_argument("url")
    f.add_argument("dir")
    a = ap.parse_args()
    {"plan": cmd_plan, "merge": cmd_merge, "fetch": cmd_fetch}[a.cmd](a)


if __name__ == "__main__":
    main()
