# SPDX-License-Identifier: GPL-3.0-or-later
"""Notice collection handles the current Wine layout and fails without debris."""

import hashlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("notices_wine", REPO / "build/notices-wine.py")
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)


class Notices(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.wine = self.root / "wine"
        self.out = self.root / "out"
        self.wine.mkdir()
        self.out.mkdir()
        (self.wine / "libs").mkdir()
        for name in notices.REQUIRED:
            (self.wine / name).write_bytes(f"fixture {name}\n".encode())

    def tearDown(self):
        self.temp.cleanup()

    def lib(self, path, content=b"fixture library notice\n"):
        file = self.wine / "libs" / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(content)
        return file

    def test_current_layout_and_recursive_inventory(self):
        text = b"Copyright fixture\r\nLicence text\xff\n"
        self.lib("symcrypt/LICENSE.txt", text)
        self.lib("nested/vendor/COPYING", b"nested notice\n")
        self.lib("unused/LICENSE", b"inventory also includes unlinked libraries\n")
        self.lib("musl/COPYRIGHT")
        self.lib("musl/source.c", b"not a notice file\n")
        names = notices.collect(self.wine, self.out)
        self.assertIn("wine-NOTICES.md", names)
        self.assertNotIn("wine-LICENSE.OLD.txt", names)
        self.assertEqual((self.out / "wine-libs-symcrypt-LICENSE.txt").read_bytes(), text)
        self.assertEqual((self.out / "wine-libs-nested-vendor-COPYING").read_bytes(), b"nested notice\n")
        self.assertIn("wine-libs-unused-LICENSE", names)
        self.assertFalse(any("source.c" in name for name in names))
        self.assertFalse(any("tomcrypt" in name for name in names))
        self.assertEqual(len(names), 8)

    def test_recursive_wine_notices_record_copy_origins(self):
        source = self.lib("nested/LICENSE", b"nested notice\n")
        log = self.out / ".copy-sources.tsv"
        names = notices.collect(self.wine, self.out, origins_log=log)
        entries = dict(line.split("\t") for line in log.read_text().splitlines())
        self.assertEqual(set(entries), set(names))
        self.assertEqual(entries["wine-libs-nested-LICENSE"], str(source))

    def test_historical_licence_is_kept_if_present(self):
        (self.wine / "LICENSE.OLD").write_bytes(b"old notice\n")
        notices.collect(self.wine, self.out)
        self.assertEqual((self.out / "wine-LICENSE.OLD.txt").read_bytes(), b"old notice\n")

    def test_missing_required_notice_writes_nothing(self):
        (self.wine / "NOTICES.md").unlink()
        with self.assertRaises(FileNotFoundError):
            notices.collect(self.wine, self.out)
        self.assertEqual(list(self.out.iterdir()), [])

    def test_existing_notice_is_not_overwritten(self):
        saved = self.out / "wine-NOTICES.md"
        saved.write_bytes(b"keep this\n")
        with self.assertRaises(ValueError):
            notices.collect(self.wine, self.out)
        self.assertEqual(saved.read_bytes(), b"keep this\n")
        self.assertEqual(list(self.out.iterdir()), [saved])

    def test_flattened_names_must_not_collide(self):
        self.lib("a/LICENSE-COPYING")
        self.lib("a-LICENSE/COPYING")
        with self.assertRaisesRegex(ValueError, "duplicate notice"):
            notices.collect(self.wine, self.out)
        self.assertEqual(list(self.out.iterdir()), [])

    def test_symlink_cannot_pull_in_an_external_file(self):
        outside = self.root / "outside"
        outside.write_bytes(b"must not be copied\n")
        folder = self.wine / "libs/example"
        folder.mkdir()
        (folder / "LICENSE").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "inside the Wine tree"):
            notices.collect(self.wine, self.out)
        self.assertEqual(list(self.out.iterdir()), [])

    def test_shell_failure_removes_partial_output(self):
        # Reach a late, required Wine-notice failure without fetching or building
        # upstream trees. Tree verification is stubbed here and tested with
        # real repositories below; copying, tar extraction and cleanup are real.
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        python = bin_dir / "python3"
        python.write_text('#!/bin/sh\n'
                          'case "$1:$2" in *notices-provenance.py:trees) '
                          'printf "{}\\n" > "$5"; exit 0 ;; *notices-rust.py:*) '
                          'printf "{}\\n" > "$7"; exit 0 ;; *notices-rust-stdlib.py:*) '
                          'printf "{}\\n" > "$5"; exit 0 ;; *notices-mingw.py:*) '
                          'exit 0 ;; *notices-gstreamer.py:*|*notices-llvm-runtime.py:*) exit 0 ;; esac\n'
                          f'exec "{sys.executable}" "$@"\n')
        python.chmod(0o755)
        crypto = self.root / "madeira/build/gnutls-ios/src"
        crypto.mkdir(parents=True)
        archive = crypto / "gmp-6.3.0.tar.xz"
        with tarfile.open(archive, "w:xz") as tar:
            for name in ("COPYINGv2", "COPYING.LESSERv3"):
                content = b"fixture licence\n"
                entry = tarfile.TarInfo("gmp-6.3.0/" + name)
                entry.size = len(content)
                tar.addfile(entry, io.BytesIO(content))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (crypto / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
        for args in (("init", "-q"), ("config", "user.name", "fixture"),
                     ("config", "user.email", "fixture@localhost"), ("add", "."),
                     ("commit", "-qm", "fixture")):
            subprocess.run(["git", "-C", str(self.wine), *args], check=True, capture_output=True)
        (self.wine / "NOTICES.md").unlink()
        destination = self.root / "notices"
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                   PLAYPORT_BUILD=str(self.root / "build"), WINE=str(self.wine),
                   MYTHIC=str(self.root / "madeira"))
        result = subprocess.run(["bash", str(REPO / "build/notices-assemble.sh"), str(destination)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Wine notice collection", result.stderr)
        self.assertIn("NOTICES.md", result.stderr)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.glob("notices.partial.*")), [])

    def test_shell_refuses_existing_output(self):
        (self.out / "keep").write_bytes(b"unchanged\n")
        result = subprocess.run(["bash", str(REPO / "build/notices-assemble.sh"), str(self.out)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertEqual((self.out / "keep").read_bytes(), b"unchanged\n")


provenance_spec = importlib.util.spec_from_file_location("notices_provenance", REPO / "build/notices-provenance.py")
provenance = importlib.util.module_from_spec(provenance_spec)
provenance_spec.loader.exec_module(provenance)


class NoticeProvenance(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.tree = self.root / "tree"
        self.tree.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "fixture")
        self.git("config", "user.email", "fixture@localhost")
        (self.tree / "LICENSE").write_text("original\n")
        self.commit()
        self.pin = self.git("rev-parse", "HEAD").strip()

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return provenance.git(self.tree, *args).decode()

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def verify(self, patches=(), **kwargs):
        return provenance.verify_tree(self.tree, self.pin, patches, self.root, **kwargs)

    def patch(self):
        (self.tree / "LICENSE").write_text("patched\n")
        self.commit()
        file = self.root / "change.patch"
        file.write_text(self.git("format-patch", "-1", "--stdout"))
        return file

    def test_exact_pin_and_path_independent_record(self):
        record = self.verify()
        self.assertEqual(record["base_commit"], self.pin)
        self.assertNotIn(str(self.root), str(record))

    def test_series_replayed_without_changing_input(self):
        patch = self.patch()
        before = self.git("status", "--porcelain")
        objects = sorted((self.tree / ".git/objects").rglob("*"))
        record = self.verify([patch])
        self.assertEqual(record["tree"], self.git("rev-parse", "HEAD^{tree}").strip())
        self.assertEqual(self.git("status", "--porcelain"), before)
        self.assertEqual(sorted((self.tree / ".git/objects").rglob("*")), objects)
        self.assertFalse((self.tree / ".git/index.lock").exists())
        self.assertEqual(list(self.root.glob("tmp*")), [])

    def test_arbitrary_descendant_rejected(self):
        self.patch()
        with self.assertRaisesRegex(ValueError, "exact pin"):
            self.verify()

    def test_changed_series_rejected(self):
        patch = self.patch()
        patch.write_text(patch.read_text().replace("+patched", "+different"))
        with self.assertRaisesRegex(ValueError, "exact pin"):
            self.verify([patch])

    def test_dirty_and_staged_notice_rejected(self):
        (self.tree / "LICENSE").write_text("dirty\n")
        with self.assertRaises(ValueError):
            self.verify()
        self.git("add", "LICENSE")
        with self.assertRaises(ValueError):
            self.verify()

    def add_child(self):
        child = self.tree / "vendor"
        child.mkdir()
        provenance.git(child, "init", "-q")
        provenance.git(child, "config", "user.name", "fixture")
        provenance.git(child, "config", "user.email", "fixture@localhost")
        (child / "LICENSE").write_text("child\n")
        provenance.git(child, "add", ".")
        provenance.git(child, "commit", "-qm", "fixture")
        self.commit()
        self.pin = self.git("rev-parse", "HEAD").strip()
        return child

    def test_submodule_dirty_and_wrong_commit_rejected(self):
        child = self.add_child()
        self.assertEqual(self.verify()["submodules"][0]["status"], "verified")
        (child / "LICENSE").write_text("changed\n")
        with self.assertRaises(ValueError):
            self.verify()
        provenance.git(child, "add", ".")
        provenance.git(child, "commit", "-qm", "extra")
        with self.assertRaisesRegex(ValueError, "exact pin"):
            self.verify()

    def test_staged_gitlink_change_rejected(self):
        child = self.add_child()
        child_pin = provenance.git(child, "rev-parse", "HEAD").decode().strip()
        (child / "LICENSE").write_text("port\n")
        provenance.git(child, "add", ".")
        provenance.git(child, "commit", "-qm", "port")
        file = self.root / "port.patch"
        file.write_bytes(provenance.git(child, "format-patch", "-1", "--stdout"))
        self.git("add", "vendor")
        with self.assertRaises(ValueError):
            self.verify(overrides={"vendor": (child_pin, [file])})

    def test_absent_required_submodule_rejected_and_optional_recorded(self):
        child = self.add_child()
        child.rename(self.root / "missing")
        self.assertEqual(self.verify()["submodules"][0]["status"], "absent-not-verified")
        with self.assertRaisesRegex(ValueError, "required notice submodule"):
            self.verify(required=("vendor",))

    def test_symlink_submodule_requires_explicit_omission(self):
        child = self.add_child()
        outside = self.root / "outside"
        child.rename(outside)
        child.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.verify()
        self.assertEqual(self.verify(omitted=("vendor",))["submodules"][0]["status"], "not-collected")

    def test_patched_submodule_override_matches_parent_pin(self):
        child = self.add_child()
        child_pin = provenance.git(child, "rev-parse", "HEAD").decode().strip()
        (child / "LICENSE").write_text("port notice\n")
        provenance.git(child, "add", ".")
        provenance.git(child, "commit", "-qm", "port")
        patch = self.root / "port.patch"
        patch.write_bytes(provenance.git(child, "format-patch", "-1", "--stdout"))
        record = self.verify(overrides={"vendor": (child_pin, [patch])})
        self.assertEqual(record["submodules"][0]["base_commit"], child_pin)
        with self.assertRaisesRegex(ValueError, "parent gitlink"):
            self.verify(overrides={"vendor": ("HEAD", [])})

    def test_tracked_notice_bytes_and_untracked_additions(self):
        self.assertEqual(provenance.tracked_file(self.tree, self.tree / "LICENSE"), "LICENSE")
        extra = self.tree / "NOTICE"
        extra.write_text("untracked\n")
        with self.assertRaisesRegex(ValueError, "untracked notice"):
            provenance.tracked_file(self.tree, extra)
        (self.tree / "LICENSE").write_text("dirty\n")
        with self.assertRaisesRegex(ValueError, "bytes differ"):
            provenance.tracked_file(self.tree, self.tree / "LICENSE")
        extra.unlink()
        extra.symlink_to(self.tree / "LICENSE")
        with self.assertRaisesRegex(ValueError, "symlink"):
            provenance.tracked_file(self.tree, extra)

    def test_copy_origins_refuse_unverified_rust_cache(self):
        out = self.root / "out"
        out.mkdir()
        rust = self.root / "rust"
        rust.mkdir()
        rust_notice = rust / "LICENSE"
        rust_notice.write_text("cached\n")
        (out / "git.txt").write_bytes((self.tree / "LICENSE").read_bytes())
        (out / "rust.txt").write_bytes(rust_notice.read_bytes())
        log = out / ".copy-sources.tsv"
        log.write_text(f"git.txt\t{self.tree / 'LICENSE'}\nrust.txt\t{rust_notice}\n")
        env = {key: str(self.tree) for key in
               ("WINE", "FEX", "MYTHIC", "DXMT", "LLVM", "FREETYPE", "MESA", "DXVK", "VKD3D", "GBE", "ABSL", "STIKJIT", "IDEVICE")}
        with patch.dict(os.environ, {**env, "RUST_ROOT": str(rust)}):
            with self.assertRaisesRegex(ValueError, "lacks locked release archive"):
                provenance.validate_copies(self.tree, log)
            log.write_text(f"git.txt\t{self.tree / 'LICENSE'}\n")
            record = provenance.validate_copies(self.tree, log)
            self.assertEqual(record["files"][0]["verification"], "committed-bytes")
            self.assertNotIn(str(self.root), str(record))
            (out / "git.txt").write_text("corrupted copy\n")
            with self.assertRaisesRegex(ValueError, "copied notice differs"):
                provenance.validate_copies(self.tree, log)

    def derived_fixture(self, entries, payload=b"notice\r\n"):
        out = self.root / "out"
        out.mkdir(exist_ok=True)
        (out / "notice.txt").write_bytes(payload)
        log = out / ".derived-sources.tsv"
        log.write_text("\n".join(entries) + "\n")
        return log

    def derived(self, log):
        with patch.object(provenance, "source_roots", return_value=[("fixture", self.tree)]):
            return provenance.validate_derived(self.tree, log)

    def archive(self, members=None):
        archive = self.tree / "vendor.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for name, content, kind in members or [("vendor/LICENSE", b"notice\r\n", tarfile.REGTYPE)]:
                member = tarfile.TarInfo(name)
                member.type = kind
                if kind == tarfile.REGTYPE:
                    member.size = len(content)
                    tar.addfile(member, io.BytesIO(content))
                else:
                    member.linkname = "vendor/LICENSE"
                    tar.addfile(member)
        self.commit()
        return archive

    def test_archive_origin_preserves_bytes_and_records_hashes(self):
        archive = self.archive()
        log = self.derived_fixture([f"archive-member\tnotice.txt\t{archive}\tvendor/LICENSE"])
        record = self.derived(log)
        entry = record["files"][0]
        self.assertEqual(entry["source"], "vendor.tar.gz")
        self.assertEqual(entry["member"], "vendor/LICENSE")
        self.assertEqual(entry["verification"], "committed-bytes")
        self.assertEqual(entry["source_sha256"], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertEqual(entry["sha256"], hashlib.sha256(b"notice\r\n").hexdigest())
        self.assertNotIn(str(self.root), str(record))
        self.assertFalse((self.root / "out/vendor").exists())

    def test_archive_missing_duplicate_and_link_members_rejected(self):
        cases = [[], [("vendor/LICENSE", b"notice\r\n", tarfile.REGTYPE)] * 2,
                 [("vendor/LICENSE", b"", tarfile.SYMTYPE)],
                 [("vendor/LICENSE", b"", tarfile.LNKTYPE)],
                 [("vendor/LICENSE", b"", tarfile.DIRTYPE)]]
        for members in cases:
            with self.subTest(members=members):
                archive = self.archive(members or [("other", b"other", tarfile.REGTYPE)])
                log = self.derived_fixture([f"archive-member\tnotice.txt\t{archive}\tvendor/LICENSE"])
                with self.assertRaisesRegex(ValueError, "one regular member"):
                    self.derived(log)

    def test_archive_unsafe_member_names_rejected(self):
        archive = self.archive()
        for member in ("../LICENSE", "/LICENSE", "vendor//LICENSE", "vendor/./LICENSE"):
            log = self.derived_fixture([f"archive-member\tnotice.txt\t{archive}\t{member}"])
            with self.assertRaisesRegex(ValueError, "unsafe archive member"):
                self.derived(log)

    def test_archive_corruption_and_untracked_sources_rejected(self):
        archive = self.archive()
        log = self.derived_fixture([f"archive-member\tnotice.txt\t{archive}\tvendor/LICENSE"])
        archive.write_bytes(b"mutated archive")
        with self.assertRaisesRegex(ValueError, "bytes differ"):
            self.derived(log)
        untracked = self.tree / "untracked.tar.gz"
        untracked.write_bytes(b"untracked")
        log = self.derived_fixture([f"archive-member\tnotice.txt\t{untracked}\tvendor/LICENSE"])
        with self.assertRaisesRegex(ValueError, "untracked notice"):
            self.derived(log)

    def test_malformed_committed_archive_rejected(self):
        archive = self.tree / "invalid.tar.gz"
        archive.write_bytes(b"not a tar archive")
        self.commit()
        log = self.derived_fixture([f"archive-member\tnotice.txt\t{archive}\tvendor/LICENSE"])
        with self.assertRaises(tarfile.TarError):
            self.derived(log)

    def test_line_excerpt_preserves_lf_crlf_and_unterminated_bytes(self):
        source = self.tree / "source.c"
        source.write_bytes(b"code\nnotice\r\nraw\xff\rend")
        self.commit()
        log = self.derived_fixture([f"line-excerpt\tnotice.txt\t{source}\t2\t3"], b"notice\r\nraw\xff\rend")
        entry = self.derived(log)["files"][0]
        self.assertEqual((entry["first_line"], entry["last_line"]), (2, 3))
        self.assertEqual(entry["source"], "source.c")
        self.assertEqual(entry["size"], len(b"notice\r\nraw\xff\rend"))

    def test_excerpt_short_source_and_invalid_selectors_rejected(self):
        source = self.tree / "LICENSE"
        for selector in ("0\t1", "2\t1", "1\t2", "one\t2", "1", "1\t1\t2"):
            log = self.derived_fixture([f"line-excerpt\tnotice.txt\t{source}\t{selector}"])
            with self.assertRaises(ValueError):
                self.derived(log)

    def test_derived_corrupt_output_and_duplicate_names_rejected(self):
        archive = self.archive()
        entry = f"archive-member\tnotice.txt\t{archive}\tvendor/LICENSE"
        log = self.derived_fixture([entry], b"corrupt extract\n")
        with self.assertRaisesRegex(ValueError, "derived notice differs"):
            self.derived(log)
        log = self.derived_fixture([entry, entry])
        with self.assertRaisesRegex(ValueError, "duplicate derived notice"):
            self.derived(log)

    def test_derived_symlinks_and_escaping_payload_names_rejected(self):
        source = self.tree / "LICENSE"
        alias = self.tree / "alias"
        alias.symlink_to(source)
        log = self.derived_fixture([f"line-excerpt\tnotice.txt\t{alias}\t1\t1"], b"original\n")
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.derived(log)
        for name in ("../LICENSE", "/LICENSE", "nested/notice.txt"):
            log = self.derived_fixture([f"line-excerpt\t{name}\t{source}\t1\t1"], b"original\n")
            with self.assertRaisesRegex(ValueError, "invalid notice output name"):
                self.derived(log)
        log = self.derived_fixture([f"line-excerpt\tnotice.txt\t{source}\t1\t1"], b"original\n")
        (log.parent / "notice.txt").unlink()
        (log.parent / "notice.txt").symlink_to(source)
        with self.assertRaisesRegex(ValueError, "regular notice payload"):
            self.derived(log)

    def test_derived_rejects_undeclared_nested_repository(self):
        child = self.tree / "unrelated"
        child.mkdir()
        for args in (("init", "-q"), ("config", "user.name", "fixture"),
                     ("config", "user.email", "fixture@localhost")):
            provenance.git(child, *args)
        (child / "LICENSE").write_bytes(b"notice\r\n")
        provenance.git(child, "add", ".")
        provenance.git(child, "commit", "-qm", "fixture")
        log = self.derived_fixture([f"line-excerpt\tnotice.txt\t{child / 'LICENSE'}\t1\t1"])
        with self.assertRaisesRegex(ValueError, "Git root escapes"):
            self.derived(log)

    def test_derived_cli_failure_does_not_write_manifest(self):
        archive = self.tree / "invalid.tar.gz"
        archive.write_bytes(b"invalid archive")
        self.commit()
        log = self.derived_fixture([f"archive-member\tnotice.txt\t{archive}\tvendor/LICENSE"])
        manifest = log.parent / "derived-origins.json"
        env = dict(os.environ, **{key: str(self.tree) for key in
                   ("WINE", "FEX", "MYTHIC", "DXMT", "LLVM", "FREETYPE", "MESA", "DXVK", "VKD3D", "GBE", "ABSL", "STIKJIT", "IDEVICE")})
        result = subprocess.run([sys.executable, str(REPO / "build/notices-provenance.py"),
                                 "derived", str(self.tree), str(log), str(manifest)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Notice provenance:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(manifest.exists())

    def test_archive_origin_in_declared_submodule(self):
        child = self.add_child()
        archive = child / "vendor.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            member = tarfile.TarInfo("vendor/LICENSE")
            member.size = len(b"notice\r\n")
            tar.addfile(member, io.BytesIO(b"notice\r\n"))
        provenance.git(child, "add", ".")
        provenance.git(child, "commit", "-qm", "archive")
        log = self.derived_fixture([f"archive-member\tnotice.txt\t{archive}\tvendor/LICENSE"])
        self.assertEqual(self.derived(log)["files"][0]["source"], "vendor/vendor.tar.gz")

    def test_manifest_hashes_all_payloads_without_local_paths(self):
        out = self.root / "out"
        out.mkdir()
        (out / "notice.txt").write_bytes(b"notice\r\n")
        (out / "tree-provenance.json").write_text("{}\n")
        (out / "SHA256SUMS").write_text("excluded\n")
        record = provenance.inventory(out)
        self.assertEqual(record["status"], "incomplete-inventory")
        self.assertEqual([f["name"] for f in record["files"]], ["notice.txt", "tree-provenance.json"])
        self.assertEqual(record["files"][0]["sha256"], hashlib.sha256(b"notice\r\n").hexdigest())
        self.assertNotIn(str(self.root), str(record))
        (out / "external").symlink_to(self.tree / "LICENSE")
        with self.assertRaisesRegex(ValueError, "regular notice"):
            provenance.inventory(out)


if __name__ == "__main__":
    unittest.main()
