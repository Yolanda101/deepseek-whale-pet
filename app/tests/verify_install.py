"""Exercise first install, upgrade and recovery in a temp directory without registering a real login item."""
import contextlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install


class InstallationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.source = root / "dist/Whale.app"
        self.destination = root / "Applications/Whale.app"
        self.plist = root / "LaunchAgents/whale.plist"
        self.helper = self.destination / "Contents/Helpers/CodexWhaleExpressions.app/Contents/MacOS/CodexWhaleExpressions"
        self.binary = self.destination / "Contents/MacOS/DeepSeekWhale"
        self.version = "1.8"
        self.encode_source()
        self.pet_running = self.helper_running = self.fail_boot = False
        context = contextlib.ExitStack()
        self.addCleanup(context.close)
        for name, value in dict(SOURCE=self.source, DEST=self.destination, PLIST=self.plist, HELPER=self.helper,
                                BINARY=self.binary, run=self.simulate, status=self.status).items():
            context.enter_context(patch.object(install, name, value))

    def encode_source(self):
        info = self.source / "Contents/Info.plist"
        info.parent.mkdir(parents=True, exist_ok=True)
        info.write_bytes(plistlib.dumps(dict(CFBundleIdentifier="com.local.deepseek.whalepet",
                                             CFBundleShortVersionString=self.version)))

    def status(self, option):
        if option == "--native-status":
            return {"running": self.helper_running, "pid": 1 if self.helper_running else None}
        installed = self.destination / "Contents/Info.plist"
        version = plistlib.loads(installed.read_bytes())["CFBundleShortVersionString"] if installed.is_file() else None
        return {"running": self.pet_running, "version": version}

    def simulate(self, *cmd, check=True):
        code, output = 0, ""
        if cmd[0] == "/usr/bin/ditto":
            shutil.copytree(cmd[1], cmd[2])
        elif cmd[0] == "/usr/bin/open":
            self.pet_running = True
        elif cmd[0] == "/bin/launchctl":
            if cmd[1] == "print":
                code = 0 if self.helper_running else 1
            elif cmd[1] == "bootstrap":
                if self.fail_boot:
                    self.fail_boot = False
                    raise RuntimeError("simulated registration failure")
                self.helper_running = True
            elif cmd[1] == "bootout":
                self.helper_running = False
        elif cmd[-1] == "--version":
            output = self.version
        elif cmd[-1] == "--quit":
            self.pet_running = False
        elif cmd[0] != "/usr/bin/codesign":
            self.fail(f"Unexpected command {cmd}")
        return subprocess.CompletedProcess(cmd, code, output, "")

    def test_first_install_and_stopped_upgrade(self):
        install.install()
        self.assertTrue(self.pet_running and self.helper_running)
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["ProgramArguments"], [str(self.helper)])
        self.pet_running = False
        self.version = "1.9"
        self.encode_source()
        install.install()
        self.assertTrue(self.helper_running)
        self.assertFalse(self.pet_running)
        self.assertEqual(self.status("--status")["version"], self.version)

    def test_registration_failure_restores_first_install(self):
        self.fail_boot = True
        with self.assertRaisesRegex(RuntimeError, "registration"):
            install.install()
        self.assertFalse(self.destination.exists() or self.plist.exists() or self.helper_running or self.pet_running)

    def test_registration_failure_restores_previous_processes(self):
        install.install()
        old = self.plist.read_bytes()
        self.version = "1.9"
        self.encode_source()
        self.fail_boot = True
        with self.assertRaisesRegex(RuntimeError, "registration"):
            install.install()
        self.assertEqual(self.status("--status")["version"], "1.8")
        self.assertEqual(self.plist.read_bytes(), old)
        self.assertTrue(self.pet_running and self.helper_running)


if __name__ == "__main__":
    unittest.main()
