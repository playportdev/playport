# SPDX-License-Identifier: GPL-3.0-or-later
"""pp source (build/source-bundle.py): an IPA's Corresponding Source, packed from exact
commits with their submodules, failing closed on anything the catalog does not account for."""

import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("source_bundle", REPO / "build/source-bundle.py")
sb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sb)

ID = ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "protocol.file.allow=always"]
FAKE = "https://fixture.invalid/"


def git(path, *args):
    return subprocess.run(["git", "-C", str(path), *ID, *args], check=True, capture_output=True,
                          text=True).stdout.strip()


def commit_tree(path, files, message="c"):
    path.mkdir(parents=True, exist_ok=True)
    if not (path / ".git").exists():
        git(path, "init", "-q", "-b", "main")
        # Fetching by commit (pp source's fetch) needs the server to allow it, as GitHub does.
        git(path, "config", "uploadpack.allowAnySHA1InWant", "true")
    for rel, data in files.items():
        (path / rel).parent.mkdir(parents=True, exist_ok=True)
        (path / rel).write_bytes(data if isinstance(data, bytes) else data.encode())
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", message)
    return git(path, "rev-parse", "HEAD")


def add_submodule(path, url, sub):
    git(path, "submodule", "add", "-q", url, sub)
    git(path, "commit", "-q", "-m", f"add {sub}")
    return git(path, "rev-parse", "HEAD")


class Fixture:
    """Upstream repositories, a superproject with pins.lock and a catalog."""

    def __init__(self, root):
        self.root = root
        up = root / "upstream"
        up.mkdir()
        self.sub = commit_tree(up / "sub", {"sub.c": "int sub;\n", "COPYING.LIB": "licence\n"})
        commit_tree(up / "bins", {"test.exe": b"MZ\0"})
        commit_tree(up / "lib", {"lib.c": "int lib;\n", "prebuilt/x.dll": b"MZ", "LICENSE": "MIT\n"})
        add_submodule(up / "lib", FAKE + "sub", "ext/sub")
        self.lib = add_submodule(up / "lib", FAKE + "bins", "ext/bins")
        self.tagged = commit_tree(up / "tagged", {"t.c": "int t;\n"})
        git(up / "tagged", "tag", "v1")
        self.urls = {n: FAKE + n for n in ("lib", "tagged")}
        self.build_dir = root / "work"
        self.tarball = self.build_dir / "cache/source/files/thing-1.tar.xz"
        self.tarball.parent.mkdir(parents=True)
        self.tarball.write_bytes(b"tarball bytes")
        self.repo = root / "playport"
        self.write_pins()
        self.catalog = root / "catalog.json"
        self.cat = {
            "schema": 1,
            "git": [
                {"name": "playport", "pin": "superproject", "why": "us"},
                {"name": "lib", "pin": "lib", "why": "a library",
                 "drop": {"prebuilt/*": "prebuilt, unused"},
                 "submodules": {"ext/bins": "test binaries"}},
                {"name": "tagged", "pin": "tagged", "tag": "v1", "commit": self.tagged, "why": "by tag"},
            ],
            "files": [{"name": "thing", "pin": "thing", "tag": "1", "file": "thing-1.tar.xz",
                       "url": FAKE + "thing-1.tar.xz", "sha256": hashlib.sha256(b"tarball bytes").hexdigest()}],
            "run_files": [{"name": "config.h", "path": "gen/config.h", "why": "generated"}],
            "missing": [],
        }
        self.save()
        self.run_dir = self.build_dir / "run"
        (self.run_dir / "gen").mkdir(parents=True)
        (self.run_dir / "gen/config.h").write_text("#define X 1\n")

    def write_pins(self, lib=None, tagged="v1", extra=None):
        pins = (f"# pins\nlib {lib or self.lib} {self.urls['lib']} main\n"
                f"tagged {tagged} {self.urls['tagged']} -\nthing 1 https://example.invalid -\n")
        self.head = commit_tree(self.repo, {"pins.lock": pins, "patches/wine/0001-a.patch": "patch a\n",
                                            "patches/wine/series": "0001-a.patch\n", "patches/empty/series": "",
                                            **(extra or {})})
        return self.head

    def save(self):
        self.catalog.write_text(json.dumps(self.cat))

    def bundle(self, out, **kw):
        kw.setdefault("run_dir", self.run_dir)
        with contextlib.redirect_stdout(io.StringIO()):
            return sb.bundle(out, repo=self.repo, build_dir=self.build_dir, catalog=self.catalog, rust_root=None,
                             say=lambda *a: None, **kw)

    def build_output(self, head=None, extra="", series=None):
        d = self.root / f"out-{len(list(self.root.glob('out-*')))}"
        d.mkdir()
        head = head or self.head
        (d / "Playport-26.5-release-unsigned-abcd.ipa").write_bytes(b"ipa")
        sha = hashlib.sha256(b"ipa").hexdigest()
        (d / "SHA256SUMS").write_text(f"{sha}  Playport-26.5-release-unsigned-abcd.ipa\n")
        (d / "pins.lock").write_bytes(subprocess.run(["git", "-C", str(self.repo), "show", f"{head}:pins.lock"],
                                                     capture_output=True, check=True).stdout)
        digest = series or {"wine": hashlib.sha256(b"patch a\n").hexdigest()[:16],
                            "empty": hashlib.sha256(b"").hexdigest()[:16]}
        (d / "provenance.txt").write_text(f"variant release unsigned\nsuperproject {head}{extra}\n"
                                          + "".join(f"series {t} {h}\n" for t, h in sorted(digest.items())))
        return d


def tgz(name):
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as z, tarfile.open(fileobj=z, mode="w") as t:
        info = tarfile.TarInfo(f"{name}/README")
        info.size = len(name)
        t.addfile(info, io.BytesIO(name.encode()))
    return buf.getvalue()


def members(path):
    with tarfile.open(path) as t:
        return {m.name: (t.extractfile(m).read() if m.isfile() else None) for m in t}


class SourceBundle(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        # The fixture's repositories have public-looking URLs (a local path in the manifest
        # would be a machine path) that git maps to them, as it would fetch from GitHub.
        env = {"GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": f"url.{(self.root / 'upstream').as_uri()}/.insteadOf",
               "GIT_CONFIG_VALUE_0": FAKE, "GIT_CONFIG_KEY_1": "protocol.file.allow",
               "GIT_CONFIG_VALUE_1": "always"}
        self.saved = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        self.f = Fixture(self.root)
        self.out = self.root / "src"

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.temp.cleanup()

    def assertStops(self, pattern, **kw):
        with self.assertRaisesRegex(sb.Stop, pattern):
            self.f.bundle(self.out, **kw)
        self.assertFalse(self.out.exists())
        self.assertEqual(list(self.out.parent.glob(f".{self.out.name}.partial-*")), [])

    def test_packs_every_tree_with_its_submodules_and_accounts_for_what_it_leaves_out(self):
        m = self.f.bundle(self.out)
        lib = members(self.out / f"lib-{self.f.lib[:10]}.tar.gz")
        p = f"lib-{self.f.lib[:10]}"
        self.assertEqual(lib[f"{p}/lib.c"], b"int lib;\n")
        self.assertEqual(lib[f"{p}/ext/sub/sub.c"], b"int sub;\n", "the submodule is expanded in place")
        self.assertNotIn(f"{p}/prebuilt/x.dll", lib)
        self.assertFalse(any("test.exe" in n for n in lib))
        entry = next(c for c in m["git"] if c["name"] == "lib")
        self.assertEqual(entry["submodules_left_out"],
                         [{"path": "ext/bins", "commit": git(self.root / "upstream/bins", "rev-parse", "HEAD"),
                           "reason": "test binaries"}])
        self.assertEqual(entry["dropped"], {"prebuilt/*": {"reason": "prebuilt, unused", "members": 1}})
        self.assertEqual([r["path"] for r in entry["repositories"]], [".", "ext/sub"])
        self.assertEqual(entry["repositories"][1]["commit"], self.f.sub)
        pp = members(self.out / f"playport-{self.f.head[:10]}.tar.gz")
        self.assertIn(f"playport-{self.f.head[:10]}/pins.lock", pp)
        self.assertEqual(m["status"], "complete")
        self.assertEqual((self.out / "thing-1.tar.xz").read_bytes(), b"tarball bytes")
        self.assertEqual((self.out / "config.h").read_text(), "#define X 1\n")
        self.assertIn("SOURCE-MANIFEST.json", (self.out / "SHA256SUMS").read_text())
        sb.check(self.out)

    def test_the_bundle_is_the_same_bytes_every_time_and_offline_from_the_cache(self):
        self.f.bundle(self.out)
        again = self.root / "again"
        self.f.bundle(again, offline=True)
        self.assertEqual((self.out / "SHA256SUMS").read_text(), (again / "SHA256SUMS").read_text())

    def test_offline_without_the_objects_stops(self):
        self.assertStops("--offline", offline=True)

    def test_a_tag_pin_that_moved_from_the_catalog_stops(self):
        self.f.write_pins(tagged="v2")
        self.assertStops("update its tag and commit")

    def test_an_unaccounted_binary_stops_and_names_every_one(self):
        del self.f.cat["git"][1]["drop"]
        self.f.save()
        self.assertStops(r"prebuilt binaries.*prebuilt/x\.dll")
        self.f.cat["git"][1]["allow_binary"] = {"prebuilt/*.dll": "a fixture"}
        self.f.save()
        self.f.bundle(self.out)

    def test_elf_content_without_a_binary_extension_or_executable_mode_stops(self):
        lib = self.root / "upstream/lib"
        self.f.lib = commit_tree(lib, {"host-tool": b"\x7fELF" + b"x" * 20000,
                                       "innocent.c": b"\x7fELF\x00native code"})
        self.assertEqual(git(lib, "ls-files", "-s", "host-tool").split()[0], "100644")
        self.f.write_pins()
        self.assertStops(r"prebuilt binaries.*host-tool.*innocent\.c")

    def test_exact_host_tool_drops_preserve_notices_scripts_and_other_data(self):
        catalog = json.loads(sb.CATALOG.read_text())
        gbe = next(c for c in catalog["git"] if c["name"] == "gbe_fork")
        drops = {p: reason for p, reason in gbe["drop"].items() if p.startswith("third-party/common/linux/")}
        self.assertEqual(set(drops), {"third-party/common/linux/premake/premake5",
                                      "third-party/common/linux/premake-arm/premake5",
                                      "third-party/common/linux/premake/libluasocket.so"})
        self.assertNotIn("third-party/common/linux/premake/libluasocket.so", gbe["allow_binary"])
        retained = {"third-party/common/linux/premake/SOURCE.txt": b"BSD licence and source references\n",
                    "third-party/common/linux/premake-arm/SOURCE.txt": b"BSD licence and source references\n",
                    "third-party/common/linux/premake/rebuild": b"#!/bin/sh\nexit 0\n",
                    "third-party/common/linux/premake/premake5.c": b"int source;\n",
                    "third-party/common/linux/premake/source.tar.gz": tgz("source"),
                    "data": b"", "short": b"\x7fEL", "not-magic": b"data\x7fELF"}
        lib = self.root / "upstream/lib"
        self.f.lib = commit_tree(lib, {**dict.fromkeys(drops, b"\x7fELFprebuilt"), **retained})
        git(lib, "update-index", "--chmod=+x", "third-party/common/linux/premake/rebuild")
        git(lib, "commit", "-q", "-m", "executable source script")
        self.f.lib = git(lib, "rev-parse", "HEAD")
        self.f.write_pins()
        self.f.cat["git"][1]["drop"].update(drops)
        self.f.save()
        manifest = self.f.bundle(self.out)
        payload = members(self.out / f"lib-{self.f.lib[:10]}.tar.gz")
        prefix = f"lib-{self.f.lib[:10]}/"
        for p, data in retained.items():
            self.assertEqual(payload[prefix + p], data)
        entry = next(c for c in manifest["git"] if c["name"] == "lib")
        for p, reason in drops.items():
            self.assertNotIn(prefix + p, payload)
            self.assertEqual(entry["dropped"][p], {"reason": reason, "members": 1})
        # A nearby native file is not covered by the exact drops.
        self.f.lib = commit_tree(lib, {"third-party/common/linux/premake/new-tool": b"\x7fELFother"})
        self.f.write_pins()
        self.out = self.root / "rejected"
        self.assertStops(r"prebuilt binaries.*premake/new-tool")

    def test_allowed_elf_and_large_streamed_data_are_unchanged_and_path_independent(self):
        elf = b"\x7fELF" + bytes(range(256)) * 10000
        data = b"source data\n" + bytes(range(256)) * 10000
        self.f.lib = commit_tree(self.root / "upstream/lib", {"host-tool": elf, "named.so": elf,
                                                             "large.data": data})
        self.f.write_pins()
        reasons = {"host-tool": "exact fixture host tool", "named.so": "exact fixture library"}
        self.f.cat["git"][1]["allow_binary"] = reasons
        for c in self.f.cat["git"][1:]:
            c["local"] = [f"repo:../upstream/{c['name']}"]
        self.f.save()
        first = self.f.bundle(self.out, offline=True)
        prefix = f"lib-{self.f.lib[:10]}"
        payload = members(self.out / f"{prefix}.tar.gz")
        for p, expected in (("host-tool", elf), ("named.so", elf), ("large.data", data)):
            self.assertEqual(payload[f"{prefix}/{p}"], expected)
        entry = next(c for c in first["git"] if c["name"] == "lib")
        self.assertEqual(entry["allowed_binaries"], {p: {"reason": reason, "members": 1}
                                                     for p, reason in reasons.items()})
        again = self.root / "different/path/src"
        other_build = self.root / "different/cache-root"
        cached = other_build / "cache/source/files" / self.f.tarball.name
        cached.parent.mkdir(parents=True)
        cached.write_bytes(self.f.tarball.read_bytes())
        sb.bundle(again, repo=self.f.repo, build_dir=other_build, offline=True,
                  catalog=self.f.catalog, run_dir=self.f.run_dir, say=lambda *a: None)
        self.assertEqual({p.name: p.read_bytes() for p in self.out.iterdir()},
                         {p.name: p.read_bytes() for p in again.iterdir()})
        sb.check(again)

    def test_binary_allowances_and_exact_drops_must_hit(self):
        for key, policy in (("allow_binary", {"lib.c": "not actually binary"}),
                            ("allow_binary", {"missing-tool": "absent"}),
                            ("drop", {"missing-tool": "absent", "prebuilt/*": "unused"})):
            with self.subTest(key=key, policy=policy):
                self.f.cat["git"][1][key] = policy
                self.f.save()
                self.assertStops("rules that match nothing")
                self.f.cat["git"][1].pop("allow_binary", None)
                self.f.cat["git"][1]["drop"] = {"prebuilt/*": "unused"}

    def test_a_rule_that_matches_nothing_stops(self):
        for key, value in (("drop", {"nothing/*": "x", "prebuilt/*": "y"}), ("keep", {"nothing/*": "x"}),
                           ("submodules", {"ext/bins": "t", "ext/gone": "x"})):
            with self.subTest(key=key):
                self.f.cat["git"][1][key] = value
                self.f.save()
                self.assertStops("rules that match nothing.*nothing|ext/gone")
                self.f.cat["git"][1].update({"drop": {"prebuilt/*": "p"}, "submodules": {"ext/bins": "t"}})
                self.f.cat["git"][1].pop("keep", None)

    def test_keep_wins_over_drop(self):
        self.f.cat["git"][1]["drop"] = {"*": "everything"}
        self.f.cat["git"][1]["keep"] = {"LICENSE": "the licence"}
        self.f.save()
        m = self.f.bundle(self.out)
        names = {n.split("/", 1)[1] for n in members(self.out / f"lib-{self.f.lib[:10]}.tar.gz")}
        self.assertEqual(names, {"LICENSE"})
        self.assertEqual(next(c for c in m["git"] if c["name"] == "lib")["submodules_left_out"][0]["path"],
                         "ext/bins")

    def test_a_submodule_without_a_url_stops(self):
        lib = self.root / "upstream/lib"
        git(lib, "config", "-f", ".gitmodules", "--remove-section", "submodule.ext/sub")
        git(lib, "commit", "-q", "-am", "drop url")
        self.f.lib = git(lib, "rev-parse", "HEAD")
        self.f.write_pins()
        self.assertStops("no URL in .gitmodules")

    def test_a_tarball_with_another_checksum_is_not_taken(self):
        self.f.tarball.write_bytes(b"changed")
        self.assertStops("--offline", offline=True)
        src = self.root / "thing"
        src.write_bytes(b"changed")
        with self.assertRaisesRegex(sb.Stop, "is sha256"):
            sb.fetch_file(src.as_uri(), self.root / "dl/thing", hashlib.sha256(b"tarball bytes").hexdigest(),
                          False, lambda *a: None)
        self.assertEqual(list((self.root / "dl").iterdir()), [], "no partial download is left")

    def gstreamer(self, release="1.28.7", stage=b"stage\n"):
        """A GStreamer lock and stage at a new superproject commit; its archives in the notice inputs' cache."""
        cache = self.f.build_dir / "cache/gstreamer-notices"
        (cache / "sources").mkdir(parents=True, exist_ok=True)
        data = {"cerbero.tar.gz": tgz("cerbero"), "sources/glib-2.82.4.tar.xz": b"glib",
                "sources/0.5.tar.gz": tgz("intl")}
        for rel, b in data.items():
            (cache / rel).write_bytes(b)
        sha = {rel: hashlib.sha256(b).hexdigest() for rel, b in data.items()}
        lock = {"schema": 1, "release": "1.28.7", "stage_sha256": hashlib.sha256(b"stage\n").hexdigest(),
                "cerbero": {"commit": "e" * 40, "tag_object": "f" * 40, "url": FAKE + "cerbero.tar.gz",
                            "sha256": sha["cerbero.tar.gz"]},
                "components": {
                    "glib": {"archive": "glib-2.82.4.tar.xz", "version": "2.82.4", "recipe": "recipes/glib.recipe",
                             "reviewed_download_url": FAKE + "glib", "sha256": sha["sources/glib-2.82.4.tar.xz"]},
                    "proxy-libintl": {"archive": "0.5.tar.gz", "version": "0.5",
                                      "recipe": "recipes/proxy-libintl.recipe",
                                      "reviewed_download_url": FAKE + "intl", "sha256": sha["sources/0.5.tar.gz"]}}}
        pins = git(self.f.repo, "show", "HEAD:pins.lock") + f"\ngstreamer {release} https://example.invalid/ios -\n"
        self.f.head = commit_tree(self.f.repo, {"pins.lock": pins, "gst.lock.json": json.dumps(lock),
                                                "gstreamer.sh": stage})
        self.f.cat["files"].append({"name": "gstreamer", "pin": "gstreamer", "gstreamer_lock": "gst.lock.json",
                                    "stage": "gstreamer.sh"})
        self.f.save()
        return sha

    def test_gstreamer_packs_cerbero_and_every_locked_archive_from_the_notice_inputs(self):
        sha = self.gstreamer()
        m = self.f.bundle(self.out)  # its URLs do not resolve: every archive comes from the cache
        got = {f["archive"]: f for f in m["files"] if f["name"] != "thing"}
        self.assertEqual(sorted(got), ["cerbero-" + "e" * 40 + ".tar.gz", "glib-2.82.4.tar.xz",
                                       "proxy-libintl-0.5.tar.gz"], "an archive named by version alone is prefixed")
        self.assertEqual((self.out / "proxy-libintl-0.5.tar.gz").read_bytes(), tgz("intl"))
        self.assertEqual(got["glib-2.82.4.tar.xz"]["sha256"], sha["sources/glib-2.82.4.tar.xz"])
        self.assertIn("recipes/glib.recipe", got["glib-2.82.4.tar.xz"]["why"])
        self.assertIn("proxy-libintl-0.5.tar.gz", (self.out / "README.md").read_text())
        sb.check(self.out)

    def test_gstreamer_stops_on_another_release_stage_or_cached_bytes(self):
        self.gstreamer(release="1.28.8")
        self.assertStops("is for GStreamer 1.28.7, pins.lock says 1.28.8")
        self.gstreamer(stage=b"changed\n")
        self.assertStops("review it again")
        self.gstreamer()
        (self.f.build_dir / "cache/gstreamer-notices/sources/glib-2.82.4.tar.xz").write_bytes(b"changed")
        self.assertStops(f"downloading {FAKE}glib failed")

    def test_a_run_file_naming_a_machine_path_stops(self):
        (self.f.run_dir / "gen/config.h").write_text("#define P \"/home/someone/x\"\n")
        self.assertStops("machine path")

    def test_a_missing_run_file_marks_the_bundle_incomplete_or_stops_a_build(self):
        (self.f.run_dir / "gen/config.h").unlink()
        m = self.f.bundle(self.out)
        self.assertEqual(m["status"], "incomplete")
        self.assertIn("Incomplete", (self.out / "README.md").read_text())
        with self.assertRaisesRegex(sb.Stop, "pack from the run"):
            self.f.bundle(self.root / "b", build=self.f.build_output())

    def test_default_catalog_is_from_the_requested_commit_not_head_or_working_copy(self):
        old_cat = {**self.f.cat, "missing": [{"what": "old gap", "why": "not verified"}]}
        committed = json.dumps(old_cat).encode()
        old = commit_tree(self.f.repo, {"build/source-bundle.json": committed})
        current = commit_tree(self.f.repo, {"build/source-bundle.json": json.dumps(self.f.cat)})
        (self.f.repo / "build/source-bundle.json").write_text("not JSON: dirty policy")
        for kind, kw in (("rev", {"rev": old}), ("build", {"build": self.f.build_output(head=old)}),
                         ("head", {"rev": current})):
            with self.subTest(kind=kind):
                out = self.root / kind
                m = sb.bundle(out, repo=self.f.repo, build_dir=self.f.build_dir, run_dir=self.f.run_dir,
                              say=lambda *a: None, **kw)
                self.assertEqual(m["status"], "complete" if kind == "head" else "incomplete")
                if kind != "head":
                    self.assertEqual(m["missing"], old_cat["missing"])
                    self.assertEqual(m["catalog_sha256"], hashlib.sha256(committed).hexdigest())

    def test_nls_data_allowance_does_not_allow_executable_binaries(self):
        lib = self.root / "upstream/lib"
        self.f.lib = commit_tree(lib, {"nls/c_1252.nls": b"locale data", "nls/program.dll": b"MZ"})
        self.f.write_pins()
        self.f.cat["git"][1]["allow_binary"] = {"nls/*.nls": "committed locale data, not code"}
        self.f.save()
        self.assertStops(r"prebuilt binaries.*nls/program\.dll")
        (lib / "nls/program.dll").unlink()
        git(lib, "commit", "-q", "-am", "remove code")
        self.f.lib = git(lib, "rev-parse", "HEAD")
        self.f.write_pins()
        self.f.bundle(self.out)
        archived = members(self.out / f"lib-{self.f.lib[:10]}.tar.gz")
        self.assertEqual(archived[f"lib-{self.f.lib[:10]}/nls/c_1252.nls"], b"locale data")

    def test_catalog_missing_entries_mark_it_incomplete(self):
        self.f.cat["missing"] = [{"what": "GStreamer sources", "why": "not pinned"}]
        self.f.save()
        m = self.f.bundle(self.out)
        self.assertEqual(m["status"], "incomplete")
        self.assertIn("GStreamer sources: not pinned", (self.out / "README.md").read_text())

    def test_a_build_output_ties_the_bundle_to_its_ipa(self):
        m = self.f.bundle(self.out, build=self.f.build_output())
        self.assertEqual(m["playport"], self.f.head)
        self.assertEqual(m["build"]["ipa_sha256"], hashlib.sha256(b"ipa").hexdigest())
        self.assertIn("Playport-26.5-release-unsigned-abcd.ipa", (self.out / "README.md").read_text())

    def test_build_series_export_matches_committed_bytes_in_every_available_locale(self):
        # Punctuation collates differently in en_US: these reproduce wine-valve's
        # 0078/0078a and 0090/0090a names without depending on the host's locale.
        self.f.head = commit_tree(self.f.repo, {
            "patches/wine/0078-z.patch": "first\n",
            "patches/wine/0078a-a.patch": "second\n",
            "patches/wine/0090-z.patch": "third\n",
            "patches/wine/0090a-a.patch": "fourth\n",
            "patches/wine/ignored.txt": "not a patch\n",
        })
        want = sb.series_digests(sb.gitdir_of(self.f.repo), self.f.head)
        locales = subprocess.run(["locale", "-a"], capture_output=True, check=True, text=True).stdout.splitlines()
        for locale in locales:
            with self.subTest(locale=locale):
                r = subprocess.run(["bash", str(REPO / "build/series-provenance.sh"),
                                    str(self.f.repo / "patches")], capture_output=True, text=True, check=True,
                                   env={**os.environ, "LC_ALL": locale})
                self.assertEqual(r.stderr, "")
                got = {line.split()[1]: line.split()[2] for line in r.stdout.splitlines()}
                self.assertEqual(got, want)
                d = self.f.build_output(series=got)
                out = self.root / f"locale-{locale}"
                self.f.bundle(out, build=d)
                self.assertEqual(json.loads((out / "SOURCE-MANIFEST.json").read_text())["playport"], self.f.head)
        self.assertIn('bash "$HERE/series-provenance.sh" "$PLAYPORT_REPO/patches"',
                      (REPO / "build/pipeline").read_text())

    def test_a_dirty_or_mismatched_build_output_stops(self):
        cases = [
            (dict(extra=" (with local changes)"), "local changes"),
            (dict(series={"wine": "0" * 16, "empty": hashlib.sha256(b"").hexdigest()[:16]}), "series lines"),
        ]
        for kw, pattern in cases:
            with self.subTest(pattern=pattern):
                self.assertStops(pattern, build=self.f.build_output(**kw))
        d = self.f.build_output()
        (d / "pins.lock").write_text("other\n")
        self.assertStops("is not .*'s pins.lock", build=d)
        d = self.f.build_output()
        (d / "Playport-26.5-release-unsigned-abcd.ipa").write_bytes(b"changed")
        self.assertStops("does not match its SHA256SUMS", build=d)

    def test_an_existing_output_is_not_touched(self):
        self.out.mkdir()
        (self.out / "keep").write_text("x")
        with self.assertRaisesRegex(sb.Stop, "already exists"):
            self.f.bundle(self.out)
        self.assertEqual((self.out / "keep").read_text(), "x")

    def test_check_finds_a_changed_or_extra_file(self):
        self.f.bundle(self.out)
        (self.out / "extra").write_text("x")
        with self.assertRaisesRegex(sb.Stop, "lists"):
            sb.check(self.out)
        (self.out / "extra").unlink()
        (self.out / "config.h").write_text("changed\n")
        with self.assertRaisesRegex(sb.Stop, "does not match"):
            sb.check(self.out)


class Crates(unittest.TestCase):
    REG = "registry+https://github.com/rust-lang/crates.io-index"

    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.rust = self.root / "rust"
        (self.rust / "cargo/registry/cache/index").mkdir(parents=True)
        self.crate = self.rust / "cargo/registry/cache/index/foo-1.0.0.crate"
        self.crate.write_bytes(b"foo crate")
        self.sha = hashlib.sha256(b"foo crate").hexdigest()

    def tearDown(self):
        self.temp.cleanup()

    def lock(self, source=None, checksum=None):
        return (f'[[package]]\nname = "ws"\nversion = "0.1.0"\n\n[[package]]\nname = "foo"\nversion = "1.0.0"\n'
                f'source = "{source or self.REG}"\nchecksum = "{checksum or self.sha}"\n')

    def crates(self, text, offline=True, url="file:///nonexistent/{name}-{version}.crate"):
        return sb.crates(text, self.REG, self.rust, self.root / "cache", url, offline, lambda *a: None)

    def test_a_locked_crate_comes_from_the_cargo_cache_when_its_checksum_matches(self):
        self.assertEqual(self.crates(self.lock()), [("foo-1.0.0.crate", self.crate, self.sha)])

    def test_a_changed_cached_crate_is_not_taken(self):
        self.crate.write_bytes(b"changed")
        with self.assertRaisesRegex(sb.Stop, "--offline"):
            self.crates(self.lock())
        good = self.root / "foo-1.0.0.crate"
        good.write_bytes(b"foo crate")
        got = self.crates(self.lock(), offline=False, url=self.root.as_uri() + "/{name}-{version}.crate")
        self.assertEqual(got[0][2], self.sha)

    def test_a_git_or_unchecksummed_package_stops(self):
        with self.assertRaisesRegex(sb.Stop, "cannot pack"):
            self.crates(self.lock(source="git+https://example.invalid/foo"))
        with self.assertRaisesRegex(sb.Stop, "no checksum"):
            self.crates(self.lock().replace(f'checksum = "{self.sha}"\n', ""))


class Catalog(unittest.TestCase):
    """The committed catalog agrees with the committed pins.lock."""

    def test_every_source_is_pinned_and_every_tag_matches(self):
        cat = json.loads(sb.CATALOG.read_text())
        pins = sb.parse_pins((REPO / "pins.lock").read_text())
        for c in cat["git"] + cat["files"]:
            if c["pin"] == "superproject":
                continue
            self.assertIn(c["pin"], pins, c["name"])
            if "tag" in c:
                self.assertEqual(pins[c["pin"]]["value"], c["tag"], f"{c['name']}: pins.lock moved its tag")
            elif "gstreamer_lock" in c:
                lock = json.loads((REPO / c["gstreamer_lock"]).read_text())
                self.assertEqual(lock["release"], pins[c["pin"]]["value"], "pins.lock moved GStreamer")
                self.assertEqual(hashlib.sha256((REPO / c["stage"]).read_bytes()).hexdigest(), lock["stage_sha256"])
            elif "lock" not in c:
                self.assertRegex(pins[c["pin"]]["value"], r"^[0-9a-f]{40}$", c["name"])
        for c in cat["git"]:
            for key in ("drop", "keep", "submodules", "allow_binary"):
                for pattern, reason in (c.get(key) or {}).items():
                    self.assertTrue(reason.strip(), f"{c['name']} {key} {pattern} has no reason")
        self.assertEqual(cat["missing"], [], "decision 0042: the bundle is complete")

    def test_resolve_url_and_store_name(self):
        self.assertEqual(sb.resolve_url("https://github.com/a/b.git", "./"), "https://github.com/a/b.git")
        self.assertEqual(sb.resolve_url("https://github.com/a/b.git", "../c.git"), "https://github.com/a/c.git")
        self.assertEqual(sb.store_name("https://github.com/a/b.git"), "github.com/a/b.git")
        with self.assertRaises(sb.Stop):
            sb.store_name("https://x/../y")


if __name__ == "__main__":
    unittest.main()
