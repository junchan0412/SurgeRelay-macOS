import XCTest
@testable import SurgeRelay

@MainActor
final class NativeQAPerformanceRecorderTests: XCTestCase {
    func testRequiresBothExplicitQAModeAndAbsoluteOutput() {
        let key = NativeQAPerformanceRecorder.outputEnvironmentKey
        XCTAssertNil(NativeQAPerformanceRecorder.outputURL(environment: [key: "/tmp/qa.jsonl"]))
        XCTAssertNil(NativeQAPerformanceRecorder.outputURL(environment: ["SURGE_RELAY_UI_QA": "1"]))
        XCTAssertNil(NativeQAPerformanceRecorder.outputURL(environment: ["SURGE_RELAY_UI_QA": "1", key: "relative.jsonl"]))
        XCTAssertEqual(NativeQAPerformanceRecorder.outputURL(environment: ["SURGE_RELAY_UI_QA": "1", key: "/tmp/qa.jsonl"])?.path, "/tmp/qa.jsonl")
    }

    func testFrameSamplingRequiresIndependentFlagAndQAOutput() {
        let output = NativeQAPerformanceRecorder.outputEnvironmentKey
        let enabled = ["SURGE_RELAY_UI_QA": "1", output: "/tmp/frames.jsonl", "SURGE_RELAY_UI_QA_FRAMES": "1"]
        XCTAssertTrue(NativeQAPerformanceRecorder.framesEnabled(environment: enabled))
        for omitted in [output, "SURGE_RELAY_UI_QA", "SURGE_RELAY_UI_QA_FRAMES"] {
            var environment = enabled
            environment.removeValue(forKey: omitted)
            XCTAssertFalse(NativeQAPerformanceRecorder.framesEnabled(environment: environment))
        }
    }

    func testFrameCadenceRecordsActualIntervalsAndOnlyEstimatesComparableGaps() throws {
        var cadence = NativeQAFrameCadence()
        XCTAssertNil(cadence.observe(time: 1, nominal: 0.01, eligible: true).interval)
        let regular = cadence.observe(time: 1.01, nominal: 0.01, eligible: true)
        XCTAssertEqual(try XCTUnwrap(regular.interval), 0.01, accuracy: 0.000001)
        XCTAssertEqual(regular.missedEstimate, 0)
        let delayed = cadence.observe(time: 1.04, nominal: 0.01, eligible: true)
        XCTAssertEqual(try XCTUnwrap(delayed.interval), 0.03, accuracy: 0.000001)
        XCTAssertEqual(delayed.missedEstimate, 2)
        XCTAssertNil(cadence.observe(time: 2, nominal: 0.01, eligible: false).missedEstimate)
        XCTAssertNil(cadence.observe(time: 3, nominal: 0.01, eligible: true).missedEstimate)
        XCTAssertNil(cadence.observe(time: 3.02, nominal: 0.02, eligible: true).missedEstimate)
        cadence.reset()
        XCTAssertNil(cadence.observe(time: 20, nominal: 0.01, eligible: true).interval)
    }

    func testFrameCadenceRejectsInvalidTimingInsteadOfInventingMisses() {
        var cadence = NativeQAFrameCadence()
        _ = cadence.observe(time: 1, nominal: 0.01, eligible: true)
        XCTAssertNil(cadence.observe(time: 0.5, nominal: 0.01, eligible: true).interval)
        XCTAssertNil(cadence.observe(time: 1, nominal: 0, eligible: true).missedEstimate)
        XCTAssertNil(cadence.observe(time: 2, nominal: .nan, eligible: true).missedEstimate)
        XCTAssertNil(cadence.observe(time: .infinity, nominal: 0.01, eligible: true).interval)
        XCTAssertNil(cadence.observe(time: 3, nominal: 0.01, eligible: true).interval)
    }

    func testGroupedTextEventsKeepIndividualLatencies() throws {
        var batch = NativeQAInputAccumulator()
        batch.keyDown(at: 1, eventTimestamp: 0.99)
        batch.textChanged(at: 1.002, documentUTF16Count: 100)
        batch.keyDown(at: 1.010, eventTimestamp: 1.009)
        batch.textChanged(at: 1.012, documentUTF16Count: 101)
        batch.textChanged(at: 1.013, documentUTF16Count: 102)
        let sample = try XCTUnwrap(batch.appKitUpdated(at: 1.020))
        XCTAssertEqual(sample.groupedEventCount, 2)
        XCTAssertEqual(sample.textChangeNotificationCount, 3)
        XCTAssertEqual(sample.documentUTF16Count, 102)
        XCTAssertEqual(sample.keyDownToAppKitUpdateMilliseconds[0], 20, accuracy: 0.0001)
        XCTAssertEqual(sample.keyDownToAppKitUpdateMilliseconds[1], 10, accuracy: 0.0001)
        XCTAssertEqual(sample.textChangeToAppKitUpdateMilliseconds[1], 8, accuracy: 0.0001)
        XCTAssertNil(batch.appKitUpdated(at: 2))
    }

    func testUntrackedChangesAndNonTextKeysDoNotBecomeInputSamples() throws {
        var batch = NativeQAInputAccumulator()
        batch.textChanged(at: 1, documentUTF16Count: 999)
        XCTAssertNil(batch.appKitUpdated(at: 2))
        batch.keyDown(at: 3, eventTimestamp: 0)
        XCTAssertNil(batch.appKitUpdated(at: 4))
        batch.keyDown(at: 5, eventTimestamp: 0)
        batch.keyDown(at: 5.01, eventTimestamp: 99)
        batch.textChanged(at: 5.02, documentUTF16Count: 300)
        let sample = try XCTUnwrap(batch.appKitUpdated(at: 5.03))
        XCTAssertEqual(sample.groupedEventCount, 1)
        XCTAssertEqual(sample.nonTextKeyDownCount, 1)
        XCTAssertNil(sample.eventTimestampToAppKitUpdateMilliseconds[0])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertNil(object["text"])
        XCTAssertNil(object["characters"])
        XCTAssertNil(object["keyCode"])
    }
}
