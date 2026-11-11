#!/usr/bin/env python3
import json
import pathlib
import subprocess
import sys


result_dir = pathlib.Path(sys.argv[1])
bundle = result_dir / "Tests.xcresult"
summary_path = result_dir / "summary.md"
summary_result = subprocess.run(
    ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
    capture_output=True, text=True,
)
if summary_result.returncode:
    summary_path.write_text("Swift QA did not produce a test summary. See `xcodebuild.log`.\n")
    print(summary_path.read_text(), end="")
    sys.exit(1)

summary = json.loads(summary_result.stdout)
(result_dir / "summary.json").write_text(summary_result.stdout)
tests_result = subprocess.run(
    ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
    capture_output=True, text=True, check=True,
)
(result_dir / "tests.json").write_text(tests_result.stdout)
tests = json.loads(tests_result.stdout)
lines = [
    f"Swift QA: **{summary['result']}** ({summary['environmentDescription']})",
    "",
    "| Executed | Passed | Failed | Skipped | Expected failures |",
    "| --- | --- | --- | --- | --- |",
    f"| {summary['totalTestCount'] - summary['skippedTests']} | {summary['passedTests']} | {summary['failedTests']} | {summary['skippedTests']} | {summary['expectedFailures']} |",
]


def skip_messages(node):
    messages = []
    if node["nodeType"] == "Test Case Run" and node.get("result") == "Skipped":
        messages.append(node["name"].removeprefix("Test skipped - "))
    for child in node.get("children", []):
        messages.extend(skip_messages(child))
    return messages


def skipped_tests(nodes):
    for node in nodes:
        if node["nodeType"] == "Test Case" and node.get("result") == "Skipped":
            yield node
        yield from skipped_tests(node.get("children", []))


skips = []
skip_details = []
for skipped in skipped_tests(tests["testNodes"]):
    test_id = skipped["nodeIdentifier"]
    detail_result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "test-details", "--path", str(bundle), "--test-id", test_id],
        capture_output=True, text=True, check=True,
    )
    detail = json.loads(detail_result.stdout)
    skip_details.append(detail)
    reasons = [message for run in detail["testRuns"] for message in skip_messages(run)]
    skips.append(f"- `{test_id}`: {'; '.join(reasons)}")
if skips:
    (result_dir / "skipped-tests.json").write_text(json.dumps(skip_details, indent=2) + "\n")
    lines.extend(["", "Skipped tests:", "", *skips])
if summary["testFailures"]:
    lines.extend(["", "Failures:", ""])
    lines.extend(f"- `{failure['testName']}`: {failure['failureText']}" for failure in summary["testFailures"])
lines.extend(["", "Native UI automation runs separately with the `Surge Relay UI Tests` scheme in a desktop session."])
summary_path.write_text("\n".join(lines) + "\n")
print(summary_path.read_text(), end="")
