#!/usr/bin/env python3
"""Enumerate a project's real dependency set and grade every licence in it.

    collect-licenses.py [--root .] [--format table|json|risk]
                        [--against LICENSES.md] [--cache ~/.cache/oss-first]

A hand-maintained ledger drifts the moment a transitive dependency changes.
This reads the lockfiles - the resolved set, not the declared one - asks the
public registries what each package is licensed under, and grades the answers
against config/license-policy.yml.

`--against` is the part that earns its keep: it does not dump 126 rows at you,
it names the packages whose licence is not `allow` and which the ledger does
not mention, plus ledger rows no lockfile backs any more.

Registries are queried over plain HTTPS with no key. Results are cached.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ALLOW = {"mit", "mit-0", "apache-2.0", "apache 2.0", "apache software license",
         "bsd", "bsd-2-clause", "bsd-3-clause", "bsd license", "isc", "mpl-2.0",
         "unlicense", "cc0-1.0", "psf-2.0", "python software foundation license",
         "zlib", "bsl-1.0", "0bsd", "postgresql", "wtfpl", "blueoak-1.0.0",
         "python-2.0", "apache-2.0 or mit", "mit or apache-2.0", "ncsa"}
REVIEW = {"lgpl", "lgpl-2.0", "lgpl-2.1", "lgpl-3.0", "gpl", "gpl-2.0", "gpl-3.0",
          "gplv2", "gplv3", "cddl-1.0", "epl-2.0", "cc-by-4.0", "ofl-1.1",
          "mpl-1.1", "artistic-2.0", "unknown", ""}
DENY = {"agpl-3.0", "agpl", "agplv3", "cc-by-nc-4.0", "cc-by-nc-sa-4.0",
        "cc-by-sa-4.0", "sspl-1.0", "busl-1.1", "elastic-2.0", "commons-clause",
        "proprietary", "none", "all rights reserved"}


def norm(lic: str | None) -> str:
    if not lic:
        return ""
    s = lic.strip().strip('"').lower()
    s = re.sub(r"\s*\(.*?\)\s*", " ", s).strip()
    s = re.sub(r"^(the\s+)?", "", s)
    s = s.replace("licence", "license")
    for pat, out in (
        (r"\bapache\b.*2", "apache-2.0"), (r"\bmit\b", "mit"),
        (r"\bagpl\b.*3|affero", "agpl-3.0"),
        (r"\blgpl\b.*3", "lgpl-3.0"), (r"\blgpl\b.*2\.1", "lgpl-2.1"),
        (r"\blgpl\b", "lgpl-2.1"),
        (r"\bgpl\b.*3", "gpl-3.0"), (r"\bgpl\b.*2", "gpl-2.0"),
        (r"mozilla public license.*2|^mpl.*2", "mpl-2.0"),
        (r"blue oak", "blueoak-1.0.0"),
        (r"python-2\.0|python software foundation", "psf-2.0"),
        (r"3-clause bsd|bsd.*3|new bsd|modified bsd", "bsd-3-clause"),
        (r"bsd.*2|simplified bsd", "bsd-2-clause"), (r"^bsd$", "bsd-3-clause"),
        (r"\bisc\b", "isc"), (r"\bmpl\b.*2", "mpl-2.0"),
        (r"python software foundation|^psf", "psf-2.0"),
        (r"noncommercial|non-commercial", "cc-by-nc-4.0"),
        (r"\bzlib\b", "zlib"), (r"unlicense|public domain", "unlicense"),
    ):
        if re.search(pat, s):
            return out
    return s[:40]


def grade(lic: str) -> str:
    n = norm(lic)
    if n in DENY:
        return "deny"
    if n in ALLOW:
        return "allow"
    if n in REVIEW or not n:
        return "review"
    for d in DENY:
        if d and d in n:
            return "deny"
    for a in ALLOW:
        if a and n.startswith(a):
            return "allow"
    return "review"


# ---------------------------------------------------------------- lockfiles

def parse_uv_lock(p: Path) -> list[tuple[str, str, str]]:
    out, name, ver = [], None, None
    for ln in p.read_text(errors="replace").splitlines():
        ln = ln.strip()
        if ln == "[[package]]":
            if name:
                out.append((name, ver or "?", "pypi"))
            name, ver = None, None
        elif ln.startswith("name = "):
            name = ln.split("=", 1)[1].strip().strip('"')
        elif ln.startswith("version = "):
            ver = ln.split("=", 1)[1].strip().strip('"')
    if name:
        out.append((name, ver or "?", "pypi"))
    return out


def parse_poetry_lock(p: Path) -> list[tuple[str, str, str]]:
    return parse_uv_lock(p)


def parse_requirements(p: Path) -> list[tuple[str, str, str]]:
    out = []
    for ln in p.read_text(errors="replace").splitlines():
        ln = ln.split("#")[0].strip()
        if not ln or ln.startswith("-"):
            continue
        m = re.match(r"^([A-Za-z0-9._-]+)\s*(?:==|>=|~=)?\s*([0-9][^\s;]*)?", ln)
        if m:
            out.append((m.group(1), m.group(2) or "?", "pypi"))
    return out


def parse_pnpm_lock(p: Path) -> list[tuple[str, str, str]]:
    out, seen = [], set()
    txt = p.read_text(errors="replace")
    # pnpm v6/v9 both key package entries by name@version under `packages:`
    for m in re.finditer(r"^\s{2,4}'?(@?[A-Za-z0-9._/-]+)@([0-9][^':\s]*)'?:", txt, re.M):
        # strip pnpm's peer-dependency suffix: "4.7.0(vite@7.3.6)" -> "4.7.0"
        ver = m.group(2).split("(")[0]
        key = (m.group(1), ver)
        if key not in seen:
            seen.add(key)
            out.append((m.group(1), ver, "npm"))
    return out


def parse_package_lock(p: Path) -> list[tuple[str, str, str]]:
    try:
        d = json.loads(p.read_text(errors="replace"))
    except json.JSONDecodeError:
        return []
    out = []
    for path, meta in (d.get("packages") or {}).items():
        if not path or not isinstance(meta, dict):
            continue
        nm = path.split("node_modules/")[-1]
        if nm:
            out.append((nm, meta.get("version") or "?", "npm"))
    return out


LOCKS = {
    "uv.lock": parse_uv_lock, "poetry.lock": parse_poetry_lock,
    "pnpm-lock.yaml": parse_pnpm_lock, "package-lock.json": parse_package_lock,
}


def discover(root: Path) -> dict[str, list[tuple[str, str, str]]]:
    found = {}
    skip = {".git", "node_modules", ".venv", "venv", "dist", "build", ".mypy_cache",
            ".ruff_cache", ".pytest_cache", "release", "vendor"}
    for p in root.rglob("*"):
        if any(s in p.parts for s in skip):
            continue
        if p.name in LOCKS:
            pkgs = LOCKS[p.name](p)
            if pkgs:
                found[str(p.relative_to(root))] = pkgs
        elif re.fullmatch(r"requirements.*\.txt", p.name) and p.is_file():
            pkgs = parse_requirements(p)
            if pkgs:
                found[str(p.relative_to(root))] = pkgs
    return found


# ---------------------------------------------------------------- registries

class Cache:
    def __init__(self, path: Path):
        self.path = path
        self.data: dict[str, str] = {}
        if path.exists():
            try:
                self.data = json.loads(path.read_text())
            except json.JSONDecodeError:
                pass

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self.data, indent=0, sort_keys=True))


def fetch(name: str, ver: str, eco: str, cache: Cache) -> str:
    key = f"{eco}:{name}:{ver}"
    if key in cache.data:
        return cache.data[key]
    url = (f"https://pypi.org/pypi/{name}/json" if eco == "pypi"
           else f"https://registry.npmjs.org/{urllib.parse.quote(name, safe='@')}")
    lic = ""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "oss-first/0.1"})
        with urllib.request.urlopen(req, timeout=20) as r:
            d = json.loads(r.read().decode())
        if eco == "pypi":
            info = d.get("info") or {}
            lic = info.get("license") or ""
            if not lic or len(lic) > 60:
                for c in info.get("classifiers") or []:
                    if c.startswith("License :: "):
                        lic = c.split("::")[-1].strip()
                        break
            le = info.get("license_expression")
            if le:
                lic = le
        else:
            vd = (d.get("versions") or {}).get(ver) or {}
            lic = vd.get("license") or d.get("license") or ""
            if isinstance(lic, dict):
                lic = lic.get("type") or ""
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError,
            TimeoutError, OSError):
        lic = ""
    cache.data[key] = lic
    return lic


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--format", choices=["table", "json", "risk"], default="risk")
    ap.add_argument("--against", help="an existing ledger markdown file to diff against")
    ap.add_argument("--cache", default=str(Path.home() / ".cache" / "oss-first" / "licenses.json"))
    ap.add_argument("--offline", action="store_true", help="use only cached licences")
    a = ap.parse_args()

    root = Path(a.root).resolve()
    locks = discover(root)
    # the project's own distribution shows up in its own lockfile; it is not a
    # third-party dependency and reporting it as "licence unknown" is noise
    own = {root.name.lower(), root.name.lower().replace("_", "-")}
    for d in ("pyproject.toml", "service/pyproject.toml", "package.json"):
        f = root / d
        if f.exists():
            m = re.search(r'^\s*name\s*[:=]\s*"?([A-Za-z0-9._-]+)', f.read_text(errors="replace"), re.M)
            if m:
                own.add(m.group(1).lower())
    if not locks:
        print(f"no lockfiles found under {root}", file=sys.stderr)
        return 1

    cache = Cache(Path(a.cache).expanduser())
    rows: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for lockfile, pkgs in locks.items():
        print(f"{lockfile}: {len(pkgs)} package(s)", file=sys.stderr)
        for name, ver, eco in pkgs:
            if (name, eco) in seen or name.lower() in own:
                continue
            seen.add((name, eco))
            lic = cache.data.get(f"{eco}:{name}:{ver}", "") if a.offline else fetch(name, ver, eco, cache)
            rows.append({"name": name, "version": ver, "ecosystem": eco,
                         "license_raw": lic, "license": norm(lic),
                         "verdict": grade(lic), "lockfile": lockfile})
    cache.save()
    rows.sort(key=lambda r: (r["verdict"] != "deny", r["verdict"] != "review", r["name"]))

    if a.format == "json":
        print(json.dumps(rows, indent=2))
        return 0

    if a.format == "table":
        print("| Package | Version | Ecosystem | License | Verdict |")
        print("| --- | --- | --- | --- | --- |")
        for r in rows:
            print(f"| {r['name']} | {r['version']} | {r['ecosystem']} | "
                  f"{r['license'] or '**unknown**'} | {r['verdict']} |")
        return 0

    # --- risk mode ---------------------------------------------------------
    counts: dict[str, int] = {}
    for r in rows:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    print(f"\n{len(rows)} distinct package(s) across {len(locks)} lockfile(s)")
    print("  " + "  ".join(f"{k}={v}" for k, v in sorted(counts.items())))

    notable = [r for r in rows if r["verdict"] in ("deny", "review")]
    ledger_text = ""
    if a.against:
        lp = Path(a.against)
        if lp.exists():
            ledger_text = lp.read_text(errors="replace").lower()
        else:
            print(f"\nwarning: ledger not found at {a.against}", file=sys.stderr)

    print(f"\n== not `allow`: {len(notable)} package(s) ==")
    unrecorded = []
    for r in notable:
        mark = ""
        if ledger_text:
            base = r["name"].lower().replace("_", "-").split("/")[-1]
            if base not in ledger_text and r["name"].lower() not in ledger_text:
                mark = "  <- NOT IN LEDGER"
                unrecorded.append(r)
        print(f"  {r['verdict']:6} {r['name']:32} {r['version']:14} "
              f"{r['license'] or 'unknown':22}{mark}")

    if ledger_text and unrecorded:
        print(f"\n{len(unrecorded)} package(s) need a ledger decision. "
              "A `review` licence with no recorded decision is an open question,\n"
              "not an approval.")

    # Two different problems wear the same shape. The same package pinned twice
    # inside ONE lockfile is a genuine smell - the resolver could not agree with
    # itself. The same package at different versions in two DIFFERENT lockfiles
    # is workspace drift, which is expected and much less interesting.
    within: dict[str, set[str]] = {}
    across: dict[str, set[str]] = {}
    for lockfile, pkgs in locks.items():
        per: dict[str, set[str]] = {}
        for name, ver, eco in pkgs:
            per.setdefault(f"{eco}:{name}", set()).add(ver)
        for k, vs in per.items():
            if len(vs) > 1:
                within.setdefault(k, set()).update(vs)
            across.setdefault(k, set()).update(vs)
    across = {k: v for k, v in across.items() if len(v) > 1 and k not in within}

    if within:
        print(f"\n== pinned twice inside one lockfile: {len(within)} ==")
        for k, vs in sorted(within.items()):
            print(f"  {k.split(':',1)[1]:32} {', '.join(sorted(vs))}")
        print("  The resolver did not settle on one version. Each of these should")
        print("  reduce to one row in the ledger, or the ledger has to say why both")
        print("  are present.")
    if across:
        print(f"\n== differs across lockfiles: {len(across)} (workspace drift, usually benign) ==")
        shown = sorted(across.items())[:12]
        for k, vs in shown:
            print(f"  {k.split(':',1)[1]:32} {', '.join(sorted(vs))}")
        if len(across) > len(shown):
            print(f"  ... and {len(across) - len(shown)} more")

    if ledger_text:
        print("\n== ledger rows no lockfile backs ==")
        stale = []
        for line in Path(a.against).read_text(errors="replace").splitlines():
            m = re.match(r"^\|\s*([A-Za-z0-9._ +-]+?)\s*[|(]", line)
            if not m:
                continue
            comp = m.group(1).strip().lower()
            if comp in ("component", "---", ""):
                continue
            first = comp.split()[0].replace("_", "-")
            if len(first) < 3:
                continue
            if not any(first in r["name"].lower().replace("_", "-") for r in rows):
                stale.append(m.group(1).strip())
        if stale:
            for s in stale:
                print(f"  {s}")
            print("  These are not in any lockfile: vendored, a system binary, a model")
            print("  weight, or a row that outlived its dependency. Each is fine, but")
            print("  each should be deliberate.")
        else:
            print("  none")

    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
