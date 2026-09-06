import Foundation
import XCTest
@testable import SurgeRelay

final class ModuleUpdatePipelineTests: XCTestCase {
    @MainActor
    func testBoundedConcurrencyPreservesSourceOrder() async {
        let tracker = PipelineTracker()
        let values = Array(0..<19)
        let results = await ModuleUpdatePipeline.run(values, maximumConcurrency: 4) { value in
            await tracker.start()
            try? await Task.sleep(for: .milliseconds(value.isMultiple(of: 2) ? 20 : 5))
            await tracker.end()
            return value
        }
        let peak = await tracker.peak
        let active = await tracker.active
        XCTAssertEqual(results, values, "Completion order must not change module merge order")
        XCTAssertEqual(peak, 4)
        XCTAssertEqual(active, 0)
    }

    @MainActor
    func testCancellationDrainsChildrenAndStopsPendingWork() async {
        let tracker = PipelineTracker()
        let started = expectation(description: "A request starts")
        let task = Task {
            await ModuleUpdatePipeline.run(Array(0..<100)) { value in
                await tracker.start()
                if value == 0 { started.fulfill() }
                try? await Task.sleep(for: .seconds(30))
                await tracker.end()
                return value
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let outputs = await task.value
        let active = await tracker.active
        XCTAssertLessThanOrEqual(outputs.count, 4)
        XCTAssertEqual(active, 0)
    }

    func testInterruptedStateRestoresOnlyInFlightModules() {
        var module = RelayModule(name: "DNS", sourceURL: "https://test.invalid/dns.sgmodule", outputFileName: "DNS")
        module.state = .updating
        XCTAssertEqual(ModuleUpdatePipeline.restoredState(for: module), .never)
        module.contentHash = "cached"
        XCTAssertEqual(ModuleUpdatePipeline.restoredState(for: module), .current)
        module.state = .failed
        XCTAssertEqual(ModuleUpdatePipeline.restoredState(for: module), .failed)
    }

    @MainActor
    func testNetworkWaitBenchmark() async {
        let inputs = Array(0..<24)
        let clock = ContinuousClock()
        var elapsed: [Duration] = []
        for concurrency in [1, 4] {
            let start = clock.now
            _ = await ModuleUpdatePipeline.run(inputs, maximumConcurrency: concurrency) { value in
                try? await Task.sleep(for: .milliseconds(25))
                return value
            }
            elapsed.append(start.duration(to: clock.now))
        }
        let report = "24 requests, each waiting 25 ms\nserial=\(elapsed[0])\nbounded4=\(elapsed[1])"
        let attachment = XCTAttachment(string: report)
        attachment.name = "relay-network-benchmark"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private actor PipelineTracker {
    var active = 0
    var peak = 0
    func start() { active += 1; peak = max(peak, active) }
    func end() { active -= 1 }
}
