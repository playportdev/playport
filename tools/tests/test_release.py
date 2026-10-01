# SPDX-License-Identifier: GPL-3.0-or-later
"""A release (decision 0038): pp verify --unsigned accepts only an ad hoc signature
with the app's entitlement and nothing of a team, profile or device, and pp release
drafts from a clean, pushed, verified build and never publishes."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import stat
import struct
import subprocess
import tarfile
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

REPO = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, REPO / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verify = load("verify_ipa", "build/verify-ipa.py")
release = load("release", "build/release.py")
ENTITLEMENTS = {"com.apple.developer.kernel.increased-memory-limit": True}


def adhoc_macho(code_body, specials, entitlements, cms=b""):
    """An arm64 MH_EXECUTE with one LC_CODE_SIGNATURE: a SHA-256 code directory over
    its code pages and special slots 1-7, an entitlements blob and a CMS blob."""
    page, nspecial, ident = 4096, 7, b"com.example.app\0"
    ents = plistlib.dumps(entitlements)
    ent_blob = struct.pack(">II", 0xfade7171, 8 + len(ents)) + ents
    cms_blob = struct.pack(">II", 0xfade0b01, 8 + len(cms)) + cms
    code_len = 48 + len(code_body) + (-(48 + len(code_body)) % 16)
    ncode = (code_len + page - 1) // page
    hoff = 0x60 + len(ident) + nspecial * 32
    cd_len = hoff + ncode * 32
    sig_len = 12 + 8 * 3 + cd_len + len(ent_blob) + len(cms_blob)
    code = (struct.pack("<IiiIIIII", 0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 1, 0)
            + struct.pack("<IIII", 0x1d, 16, code_len, sig_len) + code_body)
    code += b"\0" * (code_len - len(code))
    specials = {**specials, 5: ent_blob}
    hashes = b"".join(hashlib.sha256(specials.get(k, b"")).digest() for k in range(nspecial, 0, -1))
    hashes += b"".join(hashlib.sha256(code[i * page:(i + 1) * page]).digest() for i in range(ncode))
    cd = struct.pack(">IIIIIIIIIBBBB", 0xfade0c02, cd_len, 0x20400, 0x2, hoff, 0x60, nspecial, ncode, code_len,
                     32, 2, 0, 12)
    cd += b"\0" * (0x60 - len(cd)) + ident + hashes
    blobs = [(0, cd), (5, ent_blob), (0x10000, cms_blob)]
    off, index, body = 12 + 8 * len(blobs), b"", b""
    for t, b in blobs:
        index += struct.pack(">II", t, off + len(body))
        body += b
    sig = struct.pack(">III", 0xfade0cc0, sig_len, len(blobs)) + index + body
    assert len(sig) == sig_len
    return code + sig


def make_app(root, entitlements=ENTITLEMENTS, bundle_id="dev.playport.app", cms=b"", profile=False):
    app = root / "Playport.app"
    app.mkdir(parents=True)
    info = plistlib.dumps({"CFBundleExecutable": "Playport", "CFBundleIdentifier": bundle_id})
    (app / "Info.plist").write_bytes(info)
    (app / "Runtime.txt").write_bytes(b"resource\n")
    if profile:
        (app / "embedded.mobileprovision").write_bytes(b"profile")
    files = [p for p in app.rglob("*") if p.is_file() and p.name != "Info.plist"]
    seal = {str(p.relative_to(app)): {"hash2": hashlib.sha256(p.read_bytes()).digest()} for p in files}
    cr = plistlib.dumps({"files2": seal})
    (app / "_CodeSignature").mkdir()
    (app / "_CodeSignature/CodeResources").write_bytes(cr)
    (app / "Playport").write_bytes(adhoc_macho(b"\x1f\x20\x03\xd5" * 64, {1: info, 3: cr}, entitlements, cms))
    return app


class Unsigned(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        verify.failures.clear()

    def tearDown(self):
        verify.failures.clear()
        self.temp.cleanup()

    def failures(self, app):
        verify.failures.clear()
        info = plistlib.loads((app / "Info.plist").read_bytes())
        with contextlib.redirect_stdout(io.StringIO()):
            verify.unsigned_checks(app, info, verify.macho(app / "Playport"))
        return list(verify.failures)

    def test_an_adhoc_app_with_its_entitlement_passes(self):
        self.assertEqual(self.failures(make_app(self.root)), [])

    def test_a_changed_code_page_or_plist_fails(self):
        app = make_app(self.root)
        exe = bytearray((app / "Playport").read_bytes())
        exe[200] ^= 1
        (app / "Playport").write_bytes(bytes(exe))
        self.assertTrue(any("code directories" in f for f in self.failures(app)))
        app = make_app(self.root / "b")
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Playport",
                                                         "CFBundleIdentifier": "dev.playport.other"}))
        self.assertTrue(any("code directories" in f for f in self.failures(app)))

    def test_team_profile_and_signer_traces_fail(self):
        cases = [
            (dict(entitlements={**ENTITLEMENTS, "application-identifier": "TEAMID.x"}), "entitlements"),
            (dict(entitlements={}), "entitlements"),
            (dict(bundle_id="XTL-TEAMIDXXXX.dev.playport.app"), "team prefix"),
            (dict(cms=b"0\x82certificate"), "CMS"),
            (dict(profile=True), "embedded.mobileprovision"),
        ]
        for i, (kw, what) in enumerate(cases):
            failures = self.failures(make_app(self.root / str(i), **kw))
            self.assertTrue(any(what in f for f in failures), (kw, failures))

    def test_an_unsealed_file_or_no_signature_fails(self):
        app = make_app(self.root)
        (app / "extra.txt").write_bytes(b"x")
        self.assertTrue(any("sealed" in f for f in self.failures(app)))
        app = make_app(self.root / "b")
        exe = (app / "Playport").read_bytes()
        (app / "Playport").write_bytes(struct.pack("<IiiIIIII", 0xfeedfacf, 0x0100000c, 0, 2, 0, 0, 1, 0) + exe[32:])
        self.assertTrue(any("LC_CODE_SIGNATURE" in f for f in self.failures(app)))


class Ok:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


class Release(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        (self.repo / "app").mkdir(parents=True)
        for f in release.PLISTS:
            (self.repo / f).write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1.0"}))
        (self.repo / "pins.lock").write_text("# fixture pins\n")
        self.catalog = {"schema": 1, "missing": [{"what": "recipient build", "why": "not yet tested"}]}
        for rel in (*release.INSTRUCTIONS, "build/source-bundle.json"):
            path = self.repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(self.catalog) + "\n" if rel.endswith(".json") else "fixture instructions\n")
        g = lambda *a: subprocess.run(["git", "-C", str(self.repo), *a], check=True, capture_output=True)
        subprocess.run(["git", "init", "-q", "--bare", str(self.root / "remote.git")], check=True)
        g("init", "-q", "-b", "main")
        g("-c", "user.name=t", "-c", "user.email=t@example.invalid", "add", ".")
        g("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "fixture")
        g("remote", "add", "origin", str(self.root / "remote.git"))
        g("push", "-q", "origin", "main")
        g("fetch", "-q", "origin")
        self.head = g("rev-parse", "HEAD").stdout.decode().strip()
        self.build = self.root / "build"
        self.output(self.head)
        self.calls = []
        self.results = {}

    def tearDown(self):
        self.temp.cleanup()

    def output(self, head, extra="", name="20260930-120000-release-unsigned-abcd1234"):
        d = self.build / "out" / name
        d.mkdir(parents=True)
        with zipfile.ZipFile(d / "Playport-26.5-release-unsigned-abcd1234.ipa", "w") as z:
            z.writestr("Payload/Playport.app/Licenses/notice.txt", "fixture notice " + head)
        (d / "artifacts.tsv").write_text("# records\n")
        (d / "provenance.txt").write_text(f"variant release unsigned\nsuperproject {head}{extra}\n")
        (d / "pins.lock").write_bytes((self.repo / "pins.lock").read_bytes())
        (d / "logs").mkdir()
        (d / "logs/build.log").write_text("producer-only log: do not attach\n")
        (d / "records").mkdir()
        (d / "records/alternate.tsv").write_text("producer-only alternate run records\n")
        self.sums(d)
        return d

    def sums(self, root):
        ipas = list(root.glob("*.ipa"))
        files = ipas + [root / "artifacts.tsv"] if ipas else [p for p in root.iterdir() if p.name != "SHA256SUMS"]
        (root / "SHA256SUMS").write_text("".join(
            f"{release.sha256(p)}  {p.name}\n" for p in sorted(files)))

    def source(self, dest, output):
        dest.mkdir()
        archive = "playport.tar.gz"
        with tarfile.open(dest / archive, "w:gz") as t:
            info = tarfile.TarInfo("playport/source.c")
            info.size = 6
            t.addfile(info, io.BytesIO(b"source"))
        manifest = {"schema": 1, "playport": self.head,
                    "catalog_sha256": release.sha256(self.repo / "build/source-bundle.json"),
                    "build": {"output": output.name, "ipa": next(output.glob("*.ipa")).name,
                              "ipa_sha256": release.sha256(next(output.glob("*.ipa"))),
                              "provenance": (output / "provenance.txt").read_text().splitlines()},
                    "status": "incomplete", "missing": self.catalog["missing"],
                    "git": [{"name": "playport", "archive": archive, "commit": self.head, "url": "fixture"}],
                    "files": [], "run_files": [], "crates": None}
        (dest / "SOURCE-MANIFEST.json").write_text(json.dumps(manifest))
        (dest / "README.md").write_text(release.sb.readme(manifest))
        self.sums(dest)

    def fake(self, cmd, **kw):
        if cmd[0] == "git":
            return subprocess.run(cmd, **kw)
        self.calls.append(cmd)
        if cmd[0] == "gh":
            key = " ".join(cmd[1:3])
        elif Path(cmd[0]).name == "pp":
            key = cmd[1]
        elif cmd[1:] and cmd[1].endswith(".py"):
            key = "distribution" if "--distribution" in cmd else Path(cmd[1]).name
        else:
            key = Path(cmd[0]).name
        if key == "source-bundle.py" and not self.results.get(key):
            self.source(Path(cmd[2]), Path(cmd[4]))
        return Ok(self.results.get(key, 0))

    def release(self, **kw):
        kw.setdefault("github", False)
        if kw["github"]:
            subprocess.run(["git", "-C", str(self.repo), "remote", "set-url", "origin",
                            "https://github.com/example/playport.git"], check=True)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            return release.release("0.1.0", repo=self.repo, build_dir=self.build, run=self.fake,
                                   which=lambda n: "/usr/bin/gh", **kw)

    def test_version_must_be_semver_and_match_both_plists(self):
        self.assertEqual(release.version_problems("0.1.0", self.repo), [])
        self.assertIn("not x.y.z", release.version_problems("v0.1", self.repo)[0])
        self.assertEqual(len(release.version_problems("0.2.0", self.repo)), 2)
        self.assertEqual(release.version_problems("0.1.0", REPO), [], "the committed plists name 0.1.0")

    def test_a_clean_release_assembles_every_file_and_builds_clean_unsigned(self):
        dest = self.release()
        self.assertEqual(sorted(p.name for p in dest.iterdir()),
                         ["INSTALL-REBUILD.tar", "NOTICES.tar", "Playport-0.1.0-source.tar", "Playport-0.1.0.ipa",
                          "RELEASE-MANIFEST.json", "RELEASE-NOTES.md", "SHA256SUMS", "artifacts.tsv", "provenance.txt"])
        source_cmd = next(c for c in self.calls if c[1].endswith("source-bundle.py"))
        self.assertEqual(source_cmd[3:], ["--build", str(next((self.build / "out").iterdir()))])
        with tarfile.open(dest / "Playport-0.1.0-source.tar") as t:
            self.assertEqual(t.getnames(), ["Playport-0.1.0-source/README.md", "Playport-0.1.0-source/SHA256SUMS",
                                            "Playport-0.1.0-source/SOURCE-MANIFEST.json",
                                            "Playport-0.1.0-source/playport.tar.gz"])
        build = self.calls[0]
        self.assertEqual(build[1:], ["--variant", "release", "--unsigned", "--clean"])
        verify_cmd = next(c for c in self.calls if c[1].endswith("verify-ipa.py"))
        sha = hashlib.sha256((dest / "Playport-0.1.0.ipa").read_bytes()).hexdigest()
        self.assertEqual(verify_cmd[3:], ["--variant", "release", "--unsigned", "--sha256", sha])
        self.assertIn(f"{sha}  Playport-0.1.0.ipa\n", (dest / "SHA256SUMS").read_text())
        notes = (dest / "RELEASE-NOTES.md").read_text()
        self.assertIn(sha, notes)
        self.assertIn(hashlib.sha256((dest / "Playport-0.1.0-source.tar").read_bytes()).hexdigest(), notes)
        self.assertIn("Do not publish", notes)
        self.assertIn(self.head, notes)
        self.assertIn("Source status: incomplete", notes)
        self.assertIn("recipient build", notes)
        sums = release.checksums(dest)
        self.assertIn("RELEASE-NOTES.md", sums)
        output = next((self.build / "out").iterdir())
        self.assertEqual(set(release.read_sums(output)), {"artifacts.tsv", next(output.glob("*.ipa")).name})
        self.assertEqual((dest / "provenance.txt").read_bytes(), (output / "provenance.txt").read_bytes())
        self.assertNotIn("logs", sums)
        self.assertNotIn("records", sums)
        self.assertNotIn("pins.lock", sums)
        manifest = json.loads((dest / "RELEASE-MANIFEST.json").read_text())
        self.assertFalse(manifest["publication_approved"])
        self.assertFalse(manifest["distribution_notices_verified"])
        self.assertEqual(set(manifest["files"]), set(sums) - {"RELEASE-MANIFEST.json"})
        for name, record in manifest["files"].items():
            self.assertEqual(record, {"sha256": sums[name], "size": (dest / name).stat().st_size})

    def test_the_draft_is_a_draft_prerelease_at_head(self):
        self.results["release view"] = 1
        dest = self.release(github=True)
        create = next(c for c in self.calls if c[:3] == ["gh", "release", "create"])
        self.assertIn("--draft", create)
        self.assertIn("--prerelease", create)
        self.assertEqual(create[create.index("--target") + 1], self.head)
        self.assertEqual(create[3], "v0.1.0")
        self.assertEqual(create[create.index("--repo") + 1], "example/playport")
        distribution = next(c for c in self.calls if "--distribution" in c)
        self.assertLess(self.calls.index(distribution), self.calls.index(create))
        self.assertIn("--notices", distribution)
        for name in ("NOTICES.tar", "INSTALL-REBUILD.tar", "RELEASE-MANIFEST.json", "RELEASE-NOTES.md"):
            self.assertTrue(any(c.endswith("/" + name) for c in create))
        with tarfile.open(dest / "NOTICES.tar") as t, zipfile.ZipFile(dest / "Playport-0.1.0.ipa") as z:
            self.assertEqual(t.extractfile("Licenses/notice.txt").read(),
                             z.read("Payload/Playport.app/Licenses/notice.txt"))
        with tarfile.open(dest / "INSTALL-REBUILD.tar") as t:
            self.assertEqual(t.getnames(), ["INSTALL-REBUILD/" + n for n in sorted(release.INSTRUCTIONS)])

    def test_an_existing_github_release_stops_it(self):
        with self.assertRaisesRegex(release.Stop, "already exists on GitHub"):
            self.release(github=True)
        self.assertFalse(any(c[:3] == ["gh", "release", "create"] for c in self.calls))

    def test_no_gh_login_does_not_upload_or_offer_a_bypass(self):
        self.results["auth status"] = 1
        self.release(github=True)
        self.assertFalse(any(c[:3] == ["gh", "release", "create"] for c in self.calls))

    def test_a_dirty_or_unpushed_checkout_stops_before_building(self):
        (self.repo / "new.txt").write_text("x")
        with self.assertRaisesRegex(release.Stop, "has changes"):
            self.release()
        (self.repo / "new.txt").unlink()
        g = lambda *a: subprocess.run(["git", "-C", str(self.repo), *a], check=True, capture_output=True)
        g("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "local")
        with self.assertRaisesRegex(release.Stop, "on no remote branch"):
            self.release()
        self.assertEqual(self.calls, [])

    def test_a_failed_gate_leaves_no_release_directory(self):
        for key, what in (("verify-ipa.py", "verify"), ("secrets", "secrets"), ("pipeline", "build"),
                          ("source-bundle.py", "pp source")):
            self.results = {key: 1}
            with self.assertRaisesRegex(release.Stop, what):
                self.release()
            self.assertEqual(list((self.build / "releases").iterdir()) if (self.build / "releases").exists() else [],
                             [], "no release directory, partial or whole")

    def test_an_output_of_another_commit_or_with_local_changes_is_refused(self):
        other = self.root / "other"
        other.mkdir()
        self.build = other
        self.output("0" * 40)
        with self.assertRaisesRegex(release.Stop, "no unsigned release output"):
            self.release(build=False)
        self.output(self.head, extra=" (with local changes)", name="20260930-130000-release-unsigned-ef012345")
        with self.assertRaisesRegex(release.Stop, "local changes"):
            self.release(build=False)

    def test_a_build_that_changes_the_checkout_stops_it(self):
        def run(cmd, **kw):
            if cmd[0].endswith("pipeline"):
                (self.repo / "app/Info.plist").write_bytes(b"changed")
            return self.fake(cmd, **kw)
        with self.assertRaisesRegex(release.Stop, "has changes"):
            with contextlib.redirect_stdout(io.StringIO()):
                release.release("0.1.0", repo=self.repo, build_dir=self.build, run=run, github=False)

    def test_an_existing_release_directory_is_not_overwritten(self):
        (self.build / "releases/v0.1.0").mkdir(parents=True)
        with self.assertRaisesRegex(release.Stop, "already exists"):
            self.release()

    def test_distribution_failure_stops_before_any_gh_call_and_rolls_back(self):
        self.results["distribution"] = 1
        with self.assertRaisesRegex(release.Stop, "distribution notice verification"):
            self.release(github=True)
        self.assertFalse(any(c[0] == "gh" for c in self.calls))
        self.assertEqual(list((self.build / "releases").iterdir()), [])

    def test_local_incomplete_assembly_does_not_require_distribution_or_print_upload(self):
        self.results["distribution"] = 1
        output = io.StringIO()
        dest = release.release("0.1.0", repo=self.repo, build_dir=self.build, run=self.fake,
                               github=False, say=lambda s: output.write(s + "\n"))
        self.assertTrue(dest.exists())
        self.assertFalse(any("--distribution" in c or c[0] == "gh" for c in self.calls))
        self.assertNotIn("gh release create", output.getvalue())

    def test_ambient_git_and_repo_overrides_do_not_redirect_reads_or_children(self):
        actual = self.fake
        def run(cmd, **kwargs):
            self.assertNotIn("GIT_DIR", kwargs.get("env", {}))
            self.assertNotIn("GIT_WORK_TREE", kwargs.get("env", {}))
            if cmd[0] != "git":
                self.assertEqual(kwargs["cwd"], self.repo)
                self.assertEqual(kwargs["env"]["PLAYPORT_REPO"], str(self.repo))
                self.assertEqual(kwargs["env"]["GH_HOST"], "github.com")
                self.assertNotIn("GH_REPO", kwargs["env"])
            return actual(cmd, **kwargs)
        with mock.patch.dict(os.environ, {"GIT_DIR": str(self.root / "wrong"), "GIT_WORK_TREE": str(self.root),
                                          "PLAYPORT_REPO": str(self.root), "GH_HOST": "other.invalid",
                                          "GH_REPO": "other/repository"}):
            release.release("0.1.0", repo=self.repo, build_dir=self.build, run=run, github=False, say=lambda s: None)

    def test_nested_non_repository_is_not_attributed_to_enclosing_checkout(self):
        nested = self.repo / ".work/nested"
        (nested / "app").mkdir(parents=True)
        for rel in release.PLISTS:
            (nested / rel).write_bytes((self.repo / rel).read_bytes())
        with self.assertRaisesRegex(release.Stop, "own Git checkout"):
            release.clean_head(nested, self.fake)

    def test_malformed_prefix_and_duplicate_provenance_do_not_match_head(self):
        output = next((self.build / "out").iterdir())
        for text in (f"variant release unsigned\nsuperproject {self.head}suffix\n",
                     f"variant release unsigned\nsuperproject {self.head}\nsuperproject {self.head}\n",
                     f"variant release unsigned\nvariant dev\nsuperproject {self.head}\n"):
            (output / "provenance.txt").write_text(text)
            self.sums(output)
            with self.assertRaisesRegex(release.Stop, "exact clean"):
                self.release(build=False)
        self.assertEqual(self.calls, [])

    def test_changed_or_unsafe_build_checksums_stop_before_children(self):
        output = next((self.build / "out").iterdir())
        for text in ("0" * 64 + "  ../escape\n", (output / "SHA256SUMS").read_text() * 2,
                     "0" * 64 + "  provenance.txt\n"):
            (output / "SHA256SUMS").write_text(text)
            with self.assertRaises(release.Stop):
                self.release(build=False)
        self.assertEqual(self.calls, [])

    def test_symlink_inputs_and_dangling_output_are_refused(self):
        output = next((self.build / "out").iterdir())
        path = output / "artifacts.tsv"
        path.unlink()
        path.symlink_to(output / "provenance.txt")
        with self.assertRaisesRegex(release.Stop, "symlink"):
            self.release(build=False)
        path.unlink()
        path.write_text("# records\n")
        self.sums(output)
        dest = self.build / "releases/v0.1.0"
        dest.parent.mkdir()
        dest.symlink_to(self.root / "absent")
        with self.assertRaisesRegex(release.Stop, "symlink"):
            self.release(build=False)
        self.assertTrue(dest.is_symlink())

    def test_a_stale_partial_is_not_removed(self):
        part = self.build / "releases" / f".v0.1.0.partial-{os.getpid()}"
        part.mkdir(parents=True)
        (part / "keep").write_text("keep")
        with self.assertRaisesRegex(release.Stop, "partial output already exists"):
            self.release(build=False)
        self.assertEqual((part / "keep").read_text(), "keep")

    def test_source_manifest_mismatch_and_false_completeness_roll_back(self):
        original = self.source
        mutations = [lambda d: d.update(playport="0" * 40),
                     lambda d: d["build"].update(ipa_sha256="0" * 64),
                     lambda d: d.update(status="complete"),
                     lambda d: d.update(status="complete", missing=[]),
                     lambda d: d.update(catalog_sha256="0" * 64),
                     lambda d: d["git"].clear()]
        for mutate in mutations:
            def source(dest, output):
                original(dest, output)
                path = dest / "SOURCE-MANIFEST.json"
                data = json.loads(path.read_text())
                mutate(data)
                path.write_text(json.dumps(data))
                self.sums(dest)
            self.source = source
            with self.assertRaises(release.Stop):
                self.release(build=False)
            self.assertEqual(list((self.build / "releases").iterdir()), [])

    def test_source_checksum_or_readme_mutation_rolls_back(self):
        original = self.source
        for refresh in (False, True):
            def source(dest, output):
                original(dest, output)
                (dest / "README.md").write_text("Complete Corresponding Source\n")
                if refresh:
                    self.sums(dest)
            self.source = source
            with self.assertRaises(release.Stop):
                self.release(build=False)
            self.assertEqual(list((self.build / "releases").iterdir()), [])

    def test_notice_links_duplicate_and_traversal_are_not_extracted(self):
        output = next((self.build / "out").iterdir())
        ipa = next(output.glob("*.ipa"))
        cases = [("../escape", 0), ("link", stat.S_IFLNK | 0o777)]
        for name, mode in cases:
            with zipfile.ZipFile(ipa, "w") as z:
                info = zipfile.ZipInfo("Payload/Playport.app/Licenses/" + name)
                info.external_attr = mode << 16
                z.writestr(info, "payload")
            self.sums(output)
            with self.assertRaises(release.Stop):
                self.release(build=False)
            self.assertEqual(list((self.build / "releases").iterdir()), [])
        with zipfile.ZipFile(ipa, "w") as z:
            z.writestr("Payload/Playport.app/Licenses/notice", "a")
            with self.assertWarns(UserWarning):
                z.writestr("Payload/Playport.app/Licenses/notice", "b")
        self.sums(output)
        with self.assertRaisesRegex(release.Stop, "duplicate"):
            self.release(build=False)

    def test_missing_notices_are_allowed_only_for_local_preparation(self):
        output = next((self.build / "out").iterdir())
        with zipfile.ZipFile(next(output.glob("*.ipa")), "w") as z:
            z.writestr("Payload/Playport.app/Playport", "fixture")
        self.sums(output)
        with self.assertRaisesRegex(release.Stop, "no matching notices"):
            self.release(build=False, github=True)
        self.assertFalse(any(c[0] == "gh" for c in self.calls))
        dest = self.release(build=False)
        self.assertNotIn("NOTICES.tar", release.checksums(dest))

    def test_non_github_origin_is_not_inferred_from_gh_cwd_or_environment(self):
        with self.assertRaisesRegex(release.Stop, "explicit GitHub"):
            release.release("0.1.0", repo=self.repo, build_dir=self.build, build=False,
                            run=self.fake, github=True, say=lambda s: None)
        self.assertEqual(self.calls, [])

    def test_real_build_contract_rejects_corruption_links_and_extra_ipa(self):
        output = next((self.build / "out").iterdir())
        ipa = next(output.glob("*.ipa"))
        for name in (ipa.name, "artifacts.tsv", "pins.lock", "provenance.txt"):
            path = output / name
            original = path.read_bytes()
            path.write_bytes(original + b"changed")
            with self.assertRaises(release.Stop):
                self.release(build=False)
            path.write_bytes(original)
            path.unlink()
            path.symlink_to(output / "logs/build.log")
            with self.assertRaisesRegex(release.Stop, "symlink"):
                self.release(build=False)
            path.unlink()
            path.write_bytes(original)
        (output / "extra.ipa").write_bytes(b"another IPA")
        with self.assertRaisesRegex(release.Stop, "exactly the selected IPA"):
            self.release(build=False)
        self.assertEqual(self.calls, [])

    def test_provenance_mutation_during_source_pack_rolls_back(self):
        original = self.fake
        def fake(cmd, **kwargs):
            result = original(cmd, **kwargs)
            if len(cmd) > 1 and cmd[1].endswith("source-bundle.py"):
                output = Path(cmd[4])
                with (output / "provenance.txt").open("ab") as f:
                    f.write(b"changed after source pack\n")
            return result
        self.fake = fake
        with self.assertRaisesRegex(release.Stop, "records changed"):
            self.release(build=False)
        self.assertEqual(list((self.build / "releases").iterdir()), [])

    def test_late_asset_mutation_blocks_upload_but_retains_local_output(self):
        self.results["release view"] = 1
        original = self.fake
        def fake(cmd, **kwargs):
            result = original(cmd, **kwargs)
            if cmd[:3] == ["gh", "auth", "status"]:
                (self.build / "releases/v0.1.0/RELEASE-NOTES.md").write_text("changed")
            return result
        self.fake = fake
        with self.assertRaisesRegex(release.Stop, "differs from SHA256SUMS"):
            self.release(github=True)
        self.assertTrue((self.build / "releases/v0.1.0").exists())
        self.assertFalse(any(c[:3] == ["gh", "release", "create"] for c in self.calls))


if __name__ == "__main__":
    unittest.main()
