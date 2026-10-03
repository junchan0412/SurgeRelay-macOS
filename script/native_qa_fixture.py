#!/usr/bin/env python3
"""Generate isolated native QA fixtures or summarize recorded AppKit input updates."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import uuid

COUNTS = (100, 1000, 5000)
TEXT_SIZES = (100 * 1024, 1024 * 1024, 5 * 1024 * 1024)
LEGACY_ID = "00000000-0000-0000-0000-000000000101"


def document_bytes(size, label):
    header = f"#!name={label}\n#!desc=Isolated native QA fixture\n\n[Rule]\n".encode()
    line = b"DOMAIN,fixture.invalid,DIRECT\n"
    remaining = size - len(header)
    if remaining < 2:
        raise ValueError("document size is smaller than its fixture header")
    lines, tail = divmod(remaining, len(line))
    if tail == 1:
        lines -= 1
        tail += len(line)
    return header + line * lines + (b"#" * (tail - 1) + b"\n" if tail else b"")


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def generate(root, counts=COUNTS):
    root = Path(root).resolve()
    temporary = Path("/tmp").resolve()
    if root == temporary or not root.is_relative_to(temporary):
        raise ValueError("fixture root must be a new child directory under /tmp")
    if root.exists():
        raise ValueError("refusing to overwrite an existing fixture root")
    if not counts or any(count not in COUNTS for count in counts):
        raise ValueError("module counts must be 100, 1000 or 5000")
    root.mkdir(parents=True)
    scenarios = []
    for count in counts:
        scenario = root / f"modules-{count}"
        configuration = scenario / "Configuration"
        cache = scenario / "Cache"
        components = cache / "Components"
        sources = scenario / "Modules"
        output = scenario / "Output"
        for folder in (configuration, components, sources, output, scenario / "Measurements"):
            folder.mkdir(parents=True)
        modules = []
        editors = []
        for index in range(count):
            module_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"surge-relay-native-qa/{count}/{index}")).upper()
            if index < len(TEXT_SIZES):
                size = TEXT_SIZES[index]
                name = ["QA Editor 100KiB", "QA Editor 1MiB", "QA Editor 5MiB"][index]
            else:
                size = 1024
                name = f"QA Module {index:05d}"
            data = document_bytes(size, name)
            filename = f"{name.replace(' ', '-')}.sgmodule"
            source = sources / filename
            source.write_bytes(data)
            (components / f"{module_id}.cache").write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()
            modules.append({
                "id": module_id, "name": name, "sourceURL": source.as_uri(), "sourceFormat": "surge",
                "outputFileName": filename, "category": "Native QA", "outputFolder": "",
                "storageLocation": "local", "storageTargets": ["local"], "localStorageRelativePath": filename,
                "preservesOutputFileName": True, "publishesStandalone": True, "isEnabled": False,
                "createdAt": "2026-10-02T00:00:00Z", "lastUpdatedAt": "2026-10-02T00:00:00Z",
                "contentHash": digest, "refreshIntervalMinutes": 0, "state": "current"
            })
            if index < len(TEXT_SIZES):
                editors.append({"moduleID": module_id, "name": name, "utf8Bytes": len(data),
                                "utf16Characters": len(data.decode().encode("utf-16-le")) // 2,
                                "sourcePath": str(source), "sha256": digest,
                                "inputOutputPath": str(scenario / "Measurements" / f"editor-{size}.jsonl")})
        write_json(configuration / "modules.json", modules)
        write_json(configuration / "settings.json", {
            "outputDirectory": str(output), "localModuleDirectory": str(sources), "localPublishedRootDirectory": str(output),
            "combinedModuleEnabled": False, "refreshIntervalMinutes": 0, "automaticallyUpdateOnLaunch": False,
            "automaticallyUpdateScriptHub": False, "automaticallyPublish": False, "watchesLocalModuleChanges": False,
            "launchAtLogin": False, "publishToLocal": False, "publishToGitHub": False, "webServerEnabled": False,
            "github": {"owner": "", "repository": "", "branch": "main", "directory": "modules"}, "githubToken": ""
        })
        write_json(configuration / "update-history.json", [])
        write_json(scenario / "workspaces.json", {"activeID": LEGACY_ID, "workspaces": [{
            "id": LEGACY_ID, "name": f"Native QA {count}", "configurationDirectory": configuration.as_uri(),
            "cacheDirectory": cache.as_uri(), "isLegacyDefault": True
        }]})
        item = {"moduleCount": count, "root": str(scenario), "editors": editors, "environment": {
            "SURGE_RELAY_UI_QA": "1", "SURGE_RELAY_UI_QA_ROOT": str(scenario),
            "SURGE_RELAY_UI_QA_INPUT_OUTPUT": str(scenario / "Measurements" / "input-updates.jsonl")
        }}
        write_json(scenario / "fixture-manifest.json", item)
        scenarios.append(item)
    result = {"root": str(root), "scenarios": scenarios,
              "notice": "Fixture generation only. No app launch, UI events, publishing, or performance measurements were performed. Use a separate inputOutputPath for each document size and run."}
    write_json(root / "fixture-manifest.json", result)
    return result


def summarize(path, minimum_events=30):
    records = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    groups = [record for record in records if record.get("type") == "input-update"]
    latencies = []
    for record in groups:
        sample = record["sample"]
        values = sample["keyDownToAppKitUpdateMilliseconds"]
        if len(values) != sample["groupedEventCount"]:
            raise ValueError("grouped event count does not match its latency array")
        if any(not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0 for value in values):
            raise ValueError("invalid latency value")
        latencies.extend(values)
    ordered = sorted(latencies)
    percentile = lambda fraction: ordered[max(0, math.ceil(len(ordered) * fraction) - 1)] if ordered else None
    return {
        "boundary": "keyDown entry to NSApplication.didUpdate; not GPU presentation or FPS",
        "aggregation": "All input-update records in this file; use one scenario and document size per output file.",
        "source": str(Path(path).resolve()), "sessionCount": sum(record.get("type") == "session" for record in records),
        "sessions": [{key: record.get(key) for key in ("sessionID", "processID", "executablePath", "bundleIdentifier")} for record in records if record.get("type") == "session"],
        "updateGroups": len(groups), "textChangingKeyEvents": len(latencies),
        "groupedUpdates": sum(record["sample"]["groupedEventCount"] > 1 for record in groups),
        "minimumEvents": minimum_events, "sampleCountSufficient": len(latencies) >= minimum_events,
        "latencyMilliseconds": {"p50": percentile(.50), "p95": percentile(.95), "max": max(ordered) if ordered else None},
        "documentUTF16Counts": sorted({record["sample"]["documentUTF16Count"] for record in groups})
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("generate")
    build.add_argument("--root", default=f"/tmp/surge-relay-native-fixture-{uuid.uuid4().hex[:10]}")
    build.add_argument("--counts", nargs="+", type=int, choices=COUNTS, default=list(COUNTS))
    summary = commands.add_parser("summarize")
    summary.add_argument("path")
    summary.add_argument("--minimum-events", type=int, default=30)
    args = parser.parse_args()
    result = generate(args.root, args.counts) if args.command == "generate" else summarize(args.path, args.minimum_events)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
