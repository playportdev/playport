# SPDX-License-Identifier: GPL-3.0-or-later
"""Native host selection without requiring Xcode on the Linux test runner."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import machine


class MacSetup(unittest.TestCase):
    def test_lockdown_domain_supports_both_cli_generations(self):
        with patch.object(machine.phonelib.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, "--domain TEXT", "")
            self.assertEqual(machine.phonelib.lockdown_domain_args("disk"), ["--domain", "disk"])
            run.return_value = subprocess.CompletedProcess([], 0, "get [domain] [key]", "")
            self.assertEqual(machine.phonelib.lockdown_domain_args("disk"), ["disk"])

    def test_xcode_and_system_usbmux_are_selected_only_on_mac(self):
        with patch.dict(os.environ, {"DARWIN_SDK": "", "DEVELOPER_DIR": ""}), \
                patch.object(sys, "platform", "darwin"), patch.object(machine, "out", return_value="/Xcode/Developer\n"):
            self.assertEqual(machine.find_darwin_sdk(), "/Xcode/Developer")
            self.assertEqual(machine.find_socket(), "/var/run/usbmuxd")
        with patch.object(sys, "platform", "linux"), patch.object(machine.phonelib, "netmuxd_unit_socket", return_value="/netmuxd"):
            self.assertEqual(machine.find_socket(), "/netmuxd")

    def test_native_sdk_is_queried_and_missing_sdk_is_an_error(self):
        with patch.object(sys, "platform", "darwin"), patch.object(machine.subprocess, "run") as run, \
                patch.object(machine.os.path, "isdir", return_value=True):
            run.return_value = subprocess.CompletedProcess([], 0, "/sdk/iPhoneOS99.sdk\n", "")
            self.assertIsNone(machine.problem("DARWIN_SDK", "/Xcode/Developer"))
            self.assertEqual(run.call_args.kwargs["env"]["DEVELOPER_DIR"], "/Xcode/Developer")
            run.return_value = subprocess.CompletedProcess([], 1, "", "not installed")
            self.assertIsNotNone(machine.problem("DARWIN_SDK", "/Xcode/Developer"))


class BuildEnvironment(unittest.TestCase):
    def environment(self, host):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, body in {
                "uname": f'echo {host}',
                "brew": 'echo /brew',
                "xcode-select": 'echo /Xcode/Developer',
                "xcrun": 'case "$*" in *iphoneos*) echo /sdk/iPhoneOS99.sdk ;; *macosx*) echo /sdk/MacOSX99.sdk ;; *libtool*) echo /Xcode/libtool ;; *) echo /Xcode/ld ;; esac',
            }.items():
                p = root / name
                p.write_text("#!/bin/sh\n" + body + "\n")
                p.chmod(0o755)
            env = {k: v for k, v in os.environ.items() if k not in
                   ("DARWIN_SDK", "LD64", "LIBTOOL", "HOST_CLANG", "HOST_CLANGXX", "PLAYPORT_USBMUX_SOCKET")}
            env.update(PATH=f"{root}:/usr/bin:/bin", PLAYPORT_BUILD=str(root))
            result = subprocess.run(["bash", "-c", '. "$1"; printf "%s\\n" "$IOSSDK" "$MACSDK" "$LD64" "${PLAYPORT_USBMUX_SOCKET-}"',
                                     "env-test", str(repo / "build/env.sh")], env=env,
                                    text=True, capture_output=True, timeout=30, check=True)
            return result.stdout.splitlines()

    def test_native_sdk_version_and_linker(self):
        self.assertEqual(self.environment("Darwin"), ["/sdk/iPhoneOS99.sdk", "/sdk/MacOSX99.sdk", "/Xcode/ld", "/var/run/usbmuxd"])

    def test_linux_keeps_its_cross_sdk_and_linker(self):
        ios, mac, linker, sock = self.environment("Linux")
        self.assertTrue(ios.endswith("iPhoneOS26.5.sdk"))
        self.assertTrue(mac.endswith("MacOSX26.5.sdk"))
        self.assertTrue(linker.endswith("inputs/apple-linker/prefix/bin/arm64-apple-darwin-ld"))
        self.assertEqual(sock, "")


if __name__ == "__main__":
    unittest.main()
