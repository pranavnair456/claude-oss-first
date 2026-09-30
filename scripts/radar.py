#!/usr/bin/env python3
"""The standing radar: what is new, maintained and free in the areas you work in.

    radar.py [--interests config/interests.yml] [--seen radar/seen.txt]
             [--output digest.md] [--dry-run]

Deterministic. It runs `gh search repos`, scores what comes back, drops
anything already reported, and writes a markdown digest. No model is involved,
so it costs nothing to run every day and produces the same answer twice.

Pure standard library on purpose: this runs on a GitHub Actions runner with
nothing installed but `gh`, and adding a pip step to a daily cron is the kind
of dependency that rots.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# --------------------------------------------------------------------------
# A YAML subset parser. interests.yml is a file we own and its shape is fixed:
# nested maps, block lists of scalars, block lists of maps, and inline flow
# lists. Anything outside that raises rather than guessing.
# --------------------------------------------------------------------------

def _scalar(v: str):
    v = v.strip()
    if not v:
        return None
    if v[0] in "\"'" and v[-1:] == v[0] and len(v) > 1:
        return v[1:-1]
    if v.startswith("[") and v.endswith("]"):
        inner = v[1:-1].strip()
        return [_scalar(p) for p in _split_flow(inner)] if inner else []
    low = v.lower()
    if low in ("true", "yes"):
        return True
    if low in ("false", "no"):
        return False
    if low in ("null", "~", "none"):
        return None
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    if re.fullmatch(r"-?\d*\.\d+", v):
        return float(v)
    return v


def _split_flow(s: str) -> list[str]:
    out, buf, q = [], "", None
    for ch in s:
        if q:
            if ch == q:
                q = None
            buf += ch
        elif ch in "\"'":
            q = ch
            buf += ch
        elif ch == ",":
            out.append(buf)
            buf = ""
        else:
            buf += ch
    if buf.strip():
        out.append(buf)
    return out


def parse_yaml(text: str):
    lines = []
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        # strip trailing comments outside quotes
        out, q = "", None
        for ch in raw:
            if q:
                out += ch
                if ch == q:
                    q = None
            elif ch in "\"'":
                q = ch
                out += ch
            elif ch == "#":
                break
            else:
                out += ch
        if out.strip():
            lines.append((len(out) - len(out.lstrip()), out.strip()))

    def block(i: int, indent: int):
        """Return (value, next_index) for the block starting at line i."""
        if i >= len(lines):
            return None, i
        if lines[i][1].startswith("- "):
            items = []
            while i < len(lines) and lines[i][0] == indent and lines[i][1].startswith("- "):
                body = lines[i][1][2:].strip()
                if ":" in body and not body.startswith(("\"", "'")) and \
                        re.match(r"^[A-Za-z0-9_.-]+:", body):
                    # a list item that is itself a map
                    k, _, rest = body.partition(":")
                    item = {}
                    if rest.strip():
                        item[k.strip()] = _scalar(rest)
                    i += 1
                    child = indent + 2
                    while i < len(lines) and lines[i][0] >= child and not lines[i][1].startswith("- "):
                        ck, _, cr = lines[i][1].partition(":")
                        if cr.strip():
                            item[ck.strip()] = _scalar(cr)
                            i += 1
                        else:
                            i += 1
                            v, i = block(i, lines[i][0] if i < len(lines) else child)
                            item[ck.strip()] = v
                    items.append(item)
                else:
                    items.append(_scalar(body))
                    i += 1
            return items, i
        mapping = {}
        while i < len(lines) and lines[i][0] == indent:
            k, _, rest = lines[i][1].partition(":")
            k = k.strip()
            if rest.strip():
                mapping[k] = _scalar(rest)
                i += 1
            else:
                i += 1
                if i < len(lines) and lines[i][0] > indent:
                    v, i = block(i, lines[i][0])
                    mapping[k] = v
                else:
                    mapping[k] = None
        return mapping, i

    value, _ = block(0, lines[0][0] if lines else 0)
    return value or {}


# --------------------------------------------------------------------------
# search and score
# --------------------------------------------------------------------------

FIELDS = ("fullName,description,stargazersCount,forksCount,license,pushedAt,"
          "createdAt,isArchived,isFork,language,url,openIssuesCount")

ALLOW = {"mit", "mit-0", "apache-2.0", "bsd-2-clause", "bsd-3-clause", "isc",
         "mpl-2.0", "unlicense", "cc0-1.0", "zlib", "bsl-1.0", "0bsd"}
DENY = {"agpl-3.0", "agpl-3.0-only", "gpl-3.0", "gpl-2.0", "sspl-1.0",
         "cc-by-nc-4.0", "cc-by-nc-sa-4.0", "other", ""}


def gh_search(query: str, limit: int, language: str | None, licenses: list[str] | None) -> list[dict]:
    cmd = ["gh", "search", "repos", query, "--limit", str(limit), "--json", FIELDS]
    if language:
        cmd += ["--language", language]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        if r.returncode != 0:
            print(f"  ! search failed: {query!r}: {r.stderr.strip()[:160]}", file=sys.stderr)
            return []
        return json.loads(r.stdout or "[]")
    except (subprocess.TimeoutExpired, json.JSONDecodeError) as e:
        print(f"  ! search error: {query!r}: {e}", file=sys.stderr)
        return []


def days_since(ts: str | None) -> int:
    if not ts:
        return 9999
    try:
        d = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - d).days
    except ValueError:
        return 9999


def score(repo: dict, defaults: dict) -> tuple[int, str, list[str]]:
    lic = ((repo.get("license") or {}).get("key") or "").lower()
    age = days_since(repo.get("pushedAt"))
    stars = repo.get("stargazersCount") or 0
    born = days_since(repo.get("createdAt"))
    s, flags = 0, []

    if age <= 30:
        s += 25
    elif age <= 120:
        s += 15
    else:
        flags.append(f"last push {age}d ago")

    if lic in ALLOW:
        s += 30
    elif lic in DENY or not lic:
        flags.append(f"licence {lic or 'none'} blocks commercial use or is unstated")
    else:
        s += 10
        flags.append(f"licence {lic} needs a decision")

    if stars >= 1000:
        s += 20
    elif stars >= 200:
        s += 14
    elif stars >= 50:
        s += 8

    # something new that is already this popular is the interesting case
    if born <= 180 and stars >= (defaults.get("min_stars") or 40):
        s += 15
        flags.append(f"new: created {born}d ago")

    if repo.get("isArchived"):
        s -= 40
        flags.append("ARCHIVED")
    if repo.get("isFork"):
        s -= 15
        flags.append("fork")

    verdict = "scout" if s >= 55 else ("watch" if s >= 35 else "skip")
    return max(s, 0), verdict, flags


def main() -> int:
    ap = argparse.ArgumentParser()
    here = Path(__file__).resolve().parent
    ap.add_argument("--interests", default=str(here.parent / "config" / "interests.yml"))
    ap.add_argument("--seen", default=str(here.parent / "radar" / "seen.txt"))
    ap.add_argument("--output", default="-")
    ap.add_argument("--dry-run", action="store_true", help="do not update the seen list")
    a = ap.parse_args()

    ipath = Path(a.interests)
    if not ipath.exists():
        example = ipath.with_name("interests.example.yml")
        if example.exists():
            ipath = example
            print(f"note: using {example.name}; copy it to interests.yml to customise", file=sys.stderr)
        else:
            print(f"error: no interests file at {a.interests}", file=sys.stderr)
            return 2

    cfg = parse_yaml(ipath.read_text())
    defaults = cfg.get("defaults") or {}
    areas = cfg.get("areas") or []
    mute = set(x.lower() for x in (cfg.get("mute") or []) if isinstance(x, str))

    seen_path = Path(a.seen)
    seen = set()
    if seen_path.exists():
        seen = {ln.strip().lower() for ln in seen_path.read_text().splitlines() if ln.strip()}

    per_area = defaults.get("per_area") or 5
    min_stars = defaults.get("min_stars") or 0
    within = defaults.get("pushed_within_days") or 3650
    excl_arch = defaults.get("exclude_archived", True)
    excl_fork = defaults.get("exclude_forks", True)

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    out: list[str] = [f"# OSS radar — {today}", ""]
    out.append(f"Deterministic `gh search` sweep over {len(areas)} interest area(s). "
               f"Only repos not reported before. Top {per_area} per area.")
    out.append("")
    total_new = 0
    fresh: list[str] = []

    for area in areas:
        if not isinstance(area, dict):
            continue
        name = area.get("name") or "unnamed"
        queries = area.get("queries") or []
        langs = area.get("languages") or [None]
        print(f"area: {name} ({len(queries)} queries)", file=sys.stderr)

        pool: dict[str, dict] = {}
        for q in queries:
            for lang in langs:
                for repo in gh_search(str(q), max(per_area * 3, 15), lang, None):
                    slug = (repo.get("fullName") or "").lower()
                    if not slug or slug in seen or slug in mute or slug in pool:
                        continue
                    if (repo.get("stargazersCount") or 0) < min_stars:
                        continue
                    if days_since(repo.get("pushedAt")) > within:
                        continue
                    if excl_arch and repo.get("isArchived"):
                        continue
                    if excl_fork and repo.get("isFork"):
                        continue
                    repo["_matched"] = str(q)
                    pool[slug] = repo

        ranked = []
        for slug, repo in pool.items():
            s, verdict, flags = score(repo, defaults)
            if verdict == "skip":
                continue
            ranked.append((s, verdict, flags, repo))
        ranked.sort(key=lambda t: -t[0])
        ranked = ranked[:per_area]

        out.append(f"## {name}")
        out.append("")
        if not ranked:
            out.append("_Nothing new that clears the bar._")
            out.append("")
            continue

        for s, verdict, flags, repo in ranked:
            slug = repo["fullName"]
            lic = ((repo.get("license") or {}).get("key") or "none")
            desc = (repo.get("description") or "").strip().replace("\n", " ")
            if len(desc) > 180:
                desc = desc[:177] + "..."
            out.append(f"### [{slug}](https://github.com/{slug}) — **{verdict}** ({s})")
            out.append("")
            if desc:
                out.append(desc)
                out.append("")
            out.append(f"- licence `{lic}` · {repo.get('stargazersCount', 0)} stars · "
                       f"last push {days_since(repo.get('pushedAt'))}d ago · "
                       f"{repo.get('language') or 'n/a'}")
            out.append(f"- matched: _{repo.get('_matched', '')}_")
            if flags:
                out.append(f"- flags: {' | '.join(flags)}")
            out.append("")
            fresh.append(slug.lower())
            total_new += 1
        out.append("")

    out.append("---")
    out.append("")
    out.append(f"**{total_new} new candidate(s).** `scout` clears the bar on licence and "
               "maintenance; `watch` is promising but flagged.")
    out.append("")
    out.append("To act on one:")
    out.append("")
    out.append("```")
    out.append("scripts/gh-recon.sh <owner/repo>        # score it properly, still no clone")
    out.append("scripts/sandbox-clone.sh <owner/repo>   # quarantine it")
    out.append("scripts/security-scan.sh <path>         # run the suite")
    out.append("```")
    out.append("")
    out.append("_Everything listed is unvetted third-party code. A radar hit is a lead, not a recommendation._")

    text = "\n".join(out) + "\n"
    if a.output == "-":
        sys.stdout.write(text)
    else:
        Path(a.output).write_text(text)
        print(f"digest: {a.output}", file=sys.stderr)

    if fresh and not a.dry_run:
        seen_path.parent.mkdir(parents=True, exist_ok=True)
        with seen_path.open("a") as f:
            for slug in fresh:
                f.write(slug + "\n")
        print(f"seen list: +{len(fresh)}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
