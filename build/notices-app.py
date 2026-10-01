#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Select the app's Licenses/ from a whole `pp notices` output (build/app-notices.json).

  notices-app.py select NOTICES OUT      the selected files, components.json, CREDITS.txt,
                                          inventory.json and SHA256SUMS into OUT (must not exist)
  notices-app.py coverage [ARTIFACTS]    every part of the IPA (app/artifacts.tsv's provenance
                                          keys and the selection's other parts) has a component

NOTICES must pass build/notices-bundle.py check. Every collected payload must be
included by a component or excluded by a group, and every include pattern must
name a collected file: a renamed or new notice fails selection instead of being
dropped or carried unreviewed. Files keep their names and bytes. components.json
lists each component's licence, what it covers, its files and the credit lines,
for the app's licences page. OUT's inventory status is `release-reviewed` only
when the selection's review status is; otherwise it is `unreviewed-app-selection`,
which `pp verify --distribution` fails. OUT is published only when complete.
"""

import argparse
import fnmatch
import importlib.util
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SELECTION = REPO / "build/app-notices.json"
ARTIFACTS = REPO / "app/artifacts.tsv"
UNREVIEWED = "unreviewed-app-selection"
_spec = importlib.util.spec_from_file_location("notices_bundle", REPO / "build/notices-bundle.py")
bundle = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bundle)


def load(path=SELECTION):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    strings = lambda v: isinstance(v, list) and all(isinstance(x, str) and x for x in v)
    if not isinstance(data, dict) or data.get("schema") != 1 or not isinstance(data.get("review"), dict) \
            or not isinstance(data["review"].get("status"), str) or not strings(data["review"].get("open", [])) \
            or not isinstance(data.get("parts"), dict) or not strings(data.get("credits")) \
            or not isinstance(data.get("components"), list) or not isinstance(data.get("exclude"), list):
        raise ValueError("app notice selection is not a schema 1 selection")
    names = set()
    for c in data["components"]:
        if not isinstance(c, dict) or not isinstance(c.get("name"), str) or not isinstance(c.get("licence"), str) \
                or not strings(c.get("covers")) or not strings(c.get("include")) or not strings(c.get("except", [])) \
                or set(c) - {"name", "licence", "covers", "include", "except"}:
            raise ValueError("app notice selection has a malformed component")
        if c["name"] in names:
            raise ValueError(f"component {c['name']} is listed twice")
        names.add(c["name"])
    for g in data["exclude"]:
        if not isinstance(g, dict) or not isinstance(g.get("why"), str) or not g["why"] or not strings(g.get("patterns")):
            raise ValueError("app notice selection has a malformed exclude group")
    return data


def match(name, patterns):
    return any(fnmatch.fnmatchcase(name, p) for p in patterns)


def classify(selection, payloads):
    """Each component's files; ValueError for an unclassified payload or an unused pattern."""
    files = {c["name"]: [] for c in selection["components"]}
    used = set()
    unclassified = []
    for name in sorted(payloads):
        hit = False
        for c in selection["components"]:
            if match(name, c.get("except", [])):
                continue
            for p in c["include"]:
                if fnmatch.fnmatchcase(name, p):
                    used.add((c["name"], p))
                    hit = True
            if match(name, c["include"]):
                files[c["name"]].append(name)
        if not hit and not any(match(name, g["patterns"]) for g in selection["exclude"]):
            unclassified.append(name)
    if unclassified:
        raise ValueError("collected files the selection does not classify: " + ", ".join(unclassified[:5])
                         + (f" (and {len(unclassified) - 5} more)" if len(unclassified) > 5 else ""))
    unused = [f"{c['name']}: {p}" for c in selection["components"] for p in c["include"] if (c["name"], p) not in used]
    if unused:
        raise ValueError("selection patterns that name no collected file: " + "; ".join(unused[:5]))
    return files


def artifact_keys(text):
    """Provenance keys of what app/artifacts.tsv puts in the IPA (gap rows put nothing)."""
    rows = [line.split("\t") for line in text.splitlines() if line and not line.startswith("#")]
    return {r[6] for r in rows if len(r) > 6 and r[0] in ("resource", "link", "source")}


def coverage(selection, artifacts_text):
    """Problems: an IPA part no component covers, or a component covering nothing known."""
    keys = artifact_keys(artifacts_text)
    known = keys | set(selection["parts"])
    covered = {k for c in selection["components"] for k in c["covers"]}
    problems = [f"no component covers {k}" for k in sorted(known - covered)]
    problems += [f"a component covers unknown part {k}" for k in sorted(covered - known)]
    return problems


def select(src, out, selection=None):
    selection = selection or load()
    src, out = Path(src), Path(os.path.abspath(out))
    if out.exists() or out.is_symlink():
        raise ValueError(f"output already exists: {out}")
    bundle.check(src)
    _, entries = bundle.read_inventory(src)
    files = classify(selection, entries)
    chosen = sorted({f for fs in files.values() for f in fs})
    for extra in ("components.json", "CREDITS.txt"):
        if extra in entries:
            raise ValueError(f"the collection already has a {extra}")
    reviewed = selection["review"]["status"] == bundle.RELEASE_STATUS
    status = bundle.RELEASE_STATUS if reviewed else UNREVIEWED
    out.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=f".{out.name}.partial.", dir=out.parent))
    try:
        stage = work / "bundle"
        for name in chosen:
            (stage / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src / name, stage / name)
            if bundle.digest(stage / name) != entries[name][1]:
                raise ValueError(f"{name} changed while it was copied")
        components = [{"name": c["name"], "licence": c["licence"], "covers": c["covers"], "files": files[c["name"]]}
                      for c in selection["components"]]
        (stage / "components.json").write_text(json.dumps(
            {"schema": 1, "status": status, "components": components, "credits": selection["credits"],
             "open": [] if reviewed else selection["review"].get("open", [])}, indent=2, sort_keys=True) + "\n")
        (stage / "CREDITS.txt").write_text("".join(line + "\n\n" for line in selection["credits"]))
        payloads = chosen + ["CREDITS.txt", "components.json"]
        inventory = [{"name": n, "size": (stage / n).stat().st_size, "sha256": bundle.digest(stage / n)}
                     for n in sorted(payloads)]
        (stage / "inventory.json").write_text(json.dumps(
            {"schema": 1, "status": status, "files": inventory}, indent=2, sort_keys=True) + "\n")
        (stage / "SHA256SUMS").write_text("".join(
            f"{bundle.digest(stage / n)}  ./{n}\n" for n in sorted(payloads + ["inventory.json"])))
        result = bundle.check(stage)
        os.rename(stage, out)   # fails, rather than replaces, if OUT appeared meanwhile
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    s = sub.add_parser("select")
    s.add_argument("notices", type=Path)
    s.add_argument("out", type=Path)
    c = sub.add_parser("coverage")
    c.add_argument("artifacts", type=Path, nargs="?", default=ARTIFACTS)
    a = ap.parse_args()
    try:
        if a.command == "coverage":
            problems = coverage(load(), a.artifacts.read_text(encoding="utf-8"))
            for p in problems:
                print(f"app notices: {p}", file=sys.stderr)
            sys.exit(1 if problems else 0)
        r = select(a.notices, a.out)
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        sys.exit(f"app notices: {exc}")
    print(f"app notices: {r['files']} files, {r['bytes']:,} B in {a.out}, status {r['status']}"
          + ("" if r["status"] == bundle.RELEASE_STATUS else " (not distributable)"))


if __name__ == "__main__":
    main()
