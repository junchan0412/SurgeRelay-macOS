import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from native_qa_fixture import document_bytes, generate, summarize, TEXT_SIZES


class NativeQAFixtureTests(unittest.TestCase):
    def test_exact_text_sizes_and_isolated_safe_configuration(self):
        for size in TEXT_SIZES:
            content = document_bytes(size, "QA Editor")
            self.assertEqual(len(content), size)
            self.assertTrue(content.endswith(b"\n"))
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            root = Path(directory) / "fixture"
            manifest = generate(root, [100])
            scenario = manifest["scenarios"][0]
            settings = json.loads((Path(scenario["root"]) / "Configuration/settings.json").read_text())
            for field in ["automaticallyPublish", "automaticallyUpdateOnLaunch", "watchesLocalModuleChanges", "publishToGitHub", "publishToLocal", "webServerEnabled"]:
                self.assertFalse(settings[field])
            modules = json.loads((Path(scenario["root"]) / "Configuration/modules.json").read_text())
            self.assertEqual(len(modules), 100)
            self.assertTrue(all(module["refreshIntervalMinutes"] == 0 for module in modules))
            for editor in scenario["editors"]:
                data = Path(editor["sourcePath"]).read_bytes()
                self.assertEqual(len(data), editor["utf8Bytes"])
                self.assertEqual(hashlib.sha256(data).hexdigest(), editor["sha256"])
                cache = Path(scenario["root"]) / "Cache/Components" / f'{editor["moduleID"]}.cache'
                self.assertEqual(cache.read_bytes(), data)
            with self.assertRaises(ValueError):
                generate(root, [100])
            with self.assertRaises(ValueError):
                generate(Path.home() / "not-qa-fixture", [100])

    def test_summary_counts_grouped_events_without_claiming_render_fps(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            path = Path(directory) / "aggregation-test.jsonl"
            records = [{"type": "session"}, {"type": "input-update", "sample": {"groupedEventCount": 2, "keyDownToAppKitUpdateMilliseconds": [10, 20], "documentUTF16Count": 102400}}]
            path.write_text("\n".join(json.dumps(record) for record in records))
            result = summarize(path, 30)
            self.assertEqual(result["textChangingKeyEvents"], 2)
            self.assertEqual(result["groupedUpdates"], 1)
            self.assertEqual(result["latencyMilliseconds"]["p95"], 20)
            self.assertFalse(result["sampleCountSufficient"])
            self.assertIn("not GPU presentation or FPS", result["boundary"])
            records[1]["sample"]["groupedEventCount"] = 3
            path.write_text("\n".join(json.dumps(record) for record in records))
            with self.assertRaises(ValueError):
                summarize(path)


if __name__ == "__main__":
    unittest.main()
