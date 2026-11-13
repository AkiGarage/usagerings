import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
module = importlib.util.spec_from_file_location("formal_guard", ROOT / "script/formal_guard.py")
guard = importlib.util.module_from_spec(module)
module.loader.exec_module(guard)


class FormalGuardTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / ".build/formal-guard-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(dir=scratch))
        (self.root / ".formal").mkdir()
        self.spec = {"tla": "Model.tla", "cfgs": ["Model.cfg"], "sources": ["Store.swift"]}
        self.files = {"Model.tla": "---- MODULE Model ----\nRule == TRUE\n====\n",
                      "Model.cfg": "CONSTANTS\n  Bound = 4\nINVARIANT Rule\n", "Store.swift": "let value = 1\n"}
        for name, content in self.files.items():
            (self.root / name).write_text(content)
        self.old = {**self.files, ".formal/guard.json": json.dumps({"specs": [self.spec]})}
        self.sync()
        self.mock = patch.object(guard, "baseline", side_effect=lambda root, path: self.old[path])
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def sync(self):
        self.spec["sync_sha256"] = {path: hashlib.sha256((self.root / path).read_bytes()).hexdigest()
                                    for path in self.files}
        (self.root / ".formal/guard.json").write_text(json.dumps({"specs": [self.spec]}))

    def testExactVerifiedUncommittedContentPasses(self):
        self.assertEqual(guard.check(self.root), [])

    def testSourceChangedAfterVerificationFails(self):
        (self.root / "Store.swift").write_text("let value = 2\n")
        self.assertTrue(any("STALE Store.swift" in p for p in guard.check(self.root)))

    def testModelChangedAfterVerificationFails(self):
        (self.root / "Model.tla").write_text(self.files["Model.tla"] + "\n")
        self.assertTrue(any("STALE Model.tla" in p for p in guard.check(self.root)))

    def testMissingSourceFingerprintFails(self):
        del self.spec["sync_sha256"]["Store.swift"]
        (self.root / ".formal/guard.json").write_text(json.dumps({"specs": [self.spec]}))
        self.assertIn("UNVERIFIED Store.swift", guard.check(self.root))

    def testWeakenedInvariantFailsEvenWithUpdatedFingerprint(self):
        (self.root / "Model.tla").write_text(self.files["Model.tla"].replace("TRUE", "FALSE"))
        self.sync()
        self.assertIn("CHANGED invariant Rule in Model.cfg", guard.check(self.root))

    def testRemovedInvariantFailsEvenWithUpdatedFingerprint(self):
        (self.root / "Model.cfg").write_text("CONSTANTS\n  Bound = 4\n")
        self.sync()
        self.assertIn("CHANGED invariant Rule in Model.cfg", guard.check(self.root))

    def testReducedBoundFailsEvenWithUpdatedFingerprint(self):
        (self.root / "Model.cfg").write_text(self.files["Model.cfg"].replace("4", "2"))
        self.sync()
        self.assertIn("CHANGED constant Bound in Model.cfg", guard.check(self.root))

    def testRemovedSourceMappingFails(self):
        self.spec["sources"] = []
        self.sync()
        self.assertIn("REMOVED sources Store.swift", guard.check(self.root))


if __name__ == "__main__":
    unittest.main()
