import Foundation
import Network
import Darwin

private final class BenchmarkHTTPFixture: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "SurgeRelay.stage-benchmark.http")
    private let lock = NSLock()
    private var requests = 0
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    let body: Data

    init(body: Data) throws {
        self.body = body
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    var port: UInt16? { (listener.port?.rawValue).flatMap { $0 == 0 ? nil : $0 } }
    var requestCount: Int { lock.withLock { requests } }

    func stop() {
        listener.cancel()
        let current = lock.withLock { Array(connections.values) }
        current.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            let request = String(decoding: data, as: UTF8.self)
            let failure = request.contains("/partial/") && request.split(separator: " ").dropFirst().first.flatMap { Int($0.split(separator: "/").last ?? "") }.map { $0 % 5 == 0 } == true
            let hit = request.contains("If-None-Match: v1") || request.lowercased().contains("if-none-match: v1")
            let status = failure ? "503 Service Unavailable" : hit ? "304 Not Modified" : "200 OK"
            let responseBody = failure ? Data("fixture failure".utf8) : hit ? Data() : body
            lock.withLock { requests += 1 }
            var response = Data("HTTP/1.1 \(status)\r\nContent-Length: \(responseBody.count)\r\nETag: v1\r\nConnection: close\r\n\r\n".utf8)
            response.append(responseBody)
            connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                connection.cancel()
                _ = self?.lock.withLock { self?.connections.removeValue(forKey: ObjectIdentifier(connection)) }
            })
        }
    }
}

private final class RSSSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum: Int64 = 0
    private var task: Task<Void, Never>?
    var peakBytes: Int64 { lock.withLock { maximum } }

    func start() {
        task = Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                if let bytes = sample() { lock.withLock { maximum = max(maximum, bytes) } }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    func stop() async { task?.cancel(); await task?.value }

    private func sample() -> Int64? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,rss="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        let rows = String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { line -> (Int32, Int32, Int64)? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]), let rss = Int64(fields[2]) else { return nil }
            return (pid, parent, rss)
        }
        var included: Set<Int32> = [getpid()]
        for _ in 0..<4 {
            for row in rows where included.contains(row.1) && row.0 != process.processIdentifier { included.insert(row.0) }
        }
        return rows.filter { included.contains($0.0) }.reduce(0) { $0 + $1.2 * 1024 }
    }
}

private struct JobResult: Codable, Sendable {
    let duration: Double
    let metrics: [StageMetric]
    let usedCache: Bool
    let failed: Bool
    let helperExecuted: Bool
}

private struct CellResult: Codable {
    let profile: String
    let cacheScenario: String
    let moduleCount: Int
    let measuredRuns: Int
    let medianBatchSeconds: Double
    let moduleP95Seconds: Double
    let stageP95Seconds: [String: Double]
    let stageSampleCounts: [String: Int]
    let bodyBytesRead: Int64?
    let outputBytesWritten: Int64?
    let httpRequests: Int
    let helperExecutions: Int
    let cacheFallbacks: Int
    let failures: Int
    let aggregateRSSSampledPeakBytes: Int64
    let cpuSecondsSelfAndReapedChildren: Double
}

private func percentile(_ values: [Double], _ percentile: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * percentile)) - 1)]
}

private func cpuSeconds() -> Double {
    var own = rusage()
    var children = rusage()
    getrusage(RUSAGE_SELF, &own)
    getrusage(RUSAGE_CHILDREN, &children)
    return [own.ru_utime, own.ru_stime, children.ru_utime, children.ru_stime].reduce(0) { $0 + Double($1.tv_sec) + Double($1.tv_usec) / 1_000_000 }
}

private func oneJob(index: Int, profile: String, scenario: String, root: URL, fixture: BenchmarkHTTPFixture,
                    session: URLSession, engine: EmbeddedScriptHubEngine, instrumented: Bool) async -> JobResult {
    let collector = StageMetricsRecorder()
    return await StageMetricsContext.$current.withValue(instrumented ? collector : nil) {
        let started = ContinuousClock.now
        let cache = root.appending(path: "cache-\(index).sgmodule")
        let target = root.appending(path: "published-\(index).sgmodule")
        let useHelper = profile == "helper" || (profile == "mixed" && index % 2 == 1)
        var helperExecuted = false
        var usedCache = false
        var failed = false
        var content: Data?
        let downloadStart = ContinuousClock.now
        var bytes: Int64?
        var status: Int?
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(fixture.port!)/\(scenario)/\(index)")!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
            if scenario == "hit" { request.setValue("v1", forHTTPHeaderField: "If-None-Match") }
            let result = try await session.data(for: request)
            bytes = Int64(result.0.count)
            status = (result.1 as? HTTPURLResponse)?.statusCode
            if instrumented { collector.recordDownload(since: downloadStart, bytesRead: bytes, statusCode: status) }
            if status == 304 {
                usedCache = true
                let stamp = ContinuousClock.now
                content = try Data(contentsOf: cache)
                if instrumented {
                    collector.record(StageMetric(stage: .cache, duration: StageMetricsRecorder.elapsed(since: stamp), bytesRead: Int64(content!.count), reason: "HTTP 304"))
                    collector.record(StageMetric(stage: .conversion, duration: 0, attempts: 0, result: .skipped, reason: "缓存命中，未执行helper"))
                }
            } else {
                guard status == 200 else { throw RelayError.httpFailure(status: status ?? 0, message: "controlled fixture") }
                let converted: String
                if useHelper {
                    helperExecuted = true
                    let literal = String(decoding: try JSONEncoder().encode(String(decoding: result.0, as: UTF8.self)), as: UTF8.self)
                    let script = "const input = \(literal); const lines = input.split('\\n').filter(x => x.startsWith('DOMAIN')).map(x => x.replace('DOMAIN-SUFFIX,','DOMAIN,')).sort(); $done({body:'#!name=Controlled helper\\n[Rule]\\n'+lines.join('\\n')});"
                    converted = try await engine.convert(script: script, requestURL: URL(string: "https://benchmark.invalid/controlled-input")!)
                } else {
                    let stamp = ContinuousClock.now
                    converted = SurgeModuleSanitizer.sanitize(String(decoding: result.0, as: UTF8.self))
                    if instrumented { collector.record(StageMetric(stage: .conversion, duration: StageMetricsRecorder.elapsed(since: stamp), bytesWritten: Int64(converted.utf8.count), reason: "production native sanitizer")) }
                }
                content = Data(converted.utf8)
                let stamp = ContinuousClock.now
                try content!.write(to: cache, options: .atomic)
                if instrumented { collector.record(StageMetric(stage: .cache, duration: StageMetricsRecorder.elapsed(since: stamp), bytesWritten: Int64(content!.count), reason: "写入受控缓存")) }
            }
        } catch {
            if status == nil, instrumented { collector.recordDownload(since: downloadStart, bytesRead: bytes, statusCode: status, error: error) }
            let stamp = ContinuousClock.now
            content = try? Data(contentsOf: cache)
            usedCache = content != nil
            failed = content == nil
            if instrumented {
                collector.record(StageMetric(stage: .cache, duration: StageMetricsRecorder.elapsed(since: stamp), bytesRead: content.map { Int64($0.count) },
                                             failedAttempts: content == nil ? 1 : 0, result: content == nil ? .failed : .completed,
                                             reason: content == nil ? "缺少缓存，无法回退" : "下载失败，沿用缓存"))
            }
        }
        if let content {
            let stamp = ContinuousClock.now
            do {
                try content.write(to: target, options: .atomic)
                if instrumented { collector.record(StageMetric(stage: .publish, duration: StageMetricsRecorder.elapsed(since: stamp), bytesWritten: Int64(content.count), reason: "真实本地文件发布")) }
            } catch { failed = true }
        }
        return JobResult(duration: StageMetricsRecorder.elapsed(since: started), metrics: collector.snapshot,
                         usedCache: usedCache, failed: failed, helperExecuted: helperExecuted)
    }
}

@main
struct StageMetricsBenchmark {
    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else {
            throw NSError(domain: "benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: benchmark_stage_metrics WORKER_PATH OUTPUT_JSON [count=24] [runs=5] [metrics=on|off]"])
        }
        let worker = URL(filePath: CommandLine.arguments[1])
        let output = URL(filePath: CommandLine.arguments[2])
        let count = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 24 : 24
        let runs = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4]) ?? 5 : 5
        let instrumented = CommandLine.arguments.count <= 5 || CommandLine.arguments[5] != "off"
        let root = FileManager.default.temporaryDirectory.appending(path: "SurgeRelay-stage-benchmark-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data(("#!name=Fixture\n[Rule]\n" + (0..<1_500).map { "DOMAIN-SUFFIX,b\($0).example,DIRECT" }.joined(separator: "\n")).utf8)
        let fixture = try BenchmarkHTTPFixture(body: body)
        defer { fixture.stop() }
        while fixture.port == nil { try await Task.sleep(for: .milliseconds(10)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 4
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let engine = EmbeddedScriptHubEngine(workerExecutableURL: worker)
        var cells: [CellResult] = []
        for profile in ["native", "helper", "mixed"] {
            for scenario in ["hit", "invalidated", "partial"] {
                let sampler = RSSSampler()
                var jobs: [JobResult] = []
                var batches: [Double] = []
                var requestsBefore = 0
                var cpuBefore = 0.0
                for iteration in 0...runs {
                    let batchRoot = root.appending(path: "\(profile)-\(scenario)-\(iteration)", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: batchRoot, withIntermediateDirectories: true)
                    for index in 0..<count where scenario != "partial" || index % 10 != 5 {
                        let cached = scenario == "hit" ? body : Data("#!name=Old fixture\n[Rule]\nDOMAIN,retained.example,DIRECT".utf8)
                        try cached.write(to: batchRoot.appending(path: "cache-\(index).sgmodule"), options: .atomic)
                    }
                    if iteration == 1 { requestsBefore = fixture.requestCount; cpuBefore = cpuSeconds(); sampler.start() }
                    let started = ContinuousClock.now
                    let result = await withTaskGroup(of: JobResult.self, returning: [JobResult].self) { group in
                        var next = 0
                        var results: [JobResult] = []
                        for index in 0..<min(count, 4) {
                            group.addTask { await oneJob(index: index, profile: profile, scenario: scenario, root: batchRoot, fixture: fixture, session: session, engine: engine, instrumented: instrumented) }
                            next += 1
                        }
                        while let result = await group.next() {
                            results.append(result)
                            if next < count {
                                let index = next
                                group.addTask { await oneJob(index: index, profile: profile, scenario: scenario, root: batchRoot, fixture: fixture, session: session, engine: engine, instrumented: instrumented) }
                                next += 1
                            }
                        }
                        return results
                    }
                    if iteration > 0 { jobs += result; batches.append(StageMetricsRecorder.elapsed(since: started)) }
                }
                await sampler.stop()
                let stages = jobs.flatMap(\.metrics)
                let p95 = Dictionary(uniqueKeysWithValues: WorkStage.allCases.compactMap { stage -> (String, Double)? in
                    let samples = stages.filter { $0.stage == stage }.map(\.duration)
                    return samples.isEmpty ? nil : (stage.rawValue, percentile(samples, 0.95))
                })
                let samples = Dictionary(uniqueKeysWithValues: WorkStage.allCases.map { stage in (stage.rawValue, stages.filter { $0.stage == stage }.count) })
                let expectedMissing = scenario == "partial" ? (0..<count).filter { $0 % 10 == 5 }.count * runs : 0
                let expectedFallbacks = scenario == "partial" ? (0..<count).filter { $0 % 10 == 0 }.count * runs : 0
                let actualFallbacks = scenario == "partial" ? jobs.filter(\.usedCache).count : 0
                guard fixture.requestCount - requestsBefore == count * runs,
                      jobs.filter(\.failed).count == expectedMissing, actualFallbacks == expectedFallbacks,
                      scenario != "invalidated" || jobs.allSatisfy({ !$0.usedCache }),
                      scenario != "hit" || jobs.allSatisfy({ $0.usedCache && !$0.helperExecuted }) else {
                    throw NSError(domain: "benchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected fixture result in \(profile)/\(scenario)"])
                }
                cells.append(CellResult(profile: profile, cacheScenario: scenario, moduleCount: count, measuredRuns: runs,
                                        medianBatchSeconds: percentile(batches, 0.5), moduleP95Seconds: percentile(jobs.map(\.duration), 0.95),
                                        stageP95Seconds: p95, stageSampleCounts: samples,
                                        bodyBytesRead: instrumented ? stages.filter { $0.stage == .download }.compactMap(\.bytesRead).reduce(0, +) : nil,
                                        outputBytesWritten: instrumented ? stages.filter { $0.stage == .publish }.compactMap(\.bytesWritten).reduce(0, +) : nil,
                                        httpRequests: fixture.requestCount - requestsBefore, helperExecutions: jobs.filter(\.helperExecuted).count,
                                        cacheFallbacks: scenario == "partial" ? jobs.filter(\.usedCache).count : 0, failures: jobs.filter(\.failed).count,
                                        aggregateRSSSampledPeakBytes: sampler.peakBytes, cpuSecondsSelfAndReapedChildren: cpuSeconds() - cpuBefore))
                print("\(profile)/\(scenario): \(cells.last!.medianBatchSeconds)s")
            }
        }
        struct Report: Encodable {
            let createdAt: Date
            let method: String
            let os: String
            let processorCount: Int
            let physicalMemoryBytes: UInt64
            let metricsEnabled: Bool
            let inputBytesPerModule: Int
            let cells: [CellResult]
        }
        let report = Report(createdAt: .now,
                            method: "Nine-cell isolated stage harness: real loopback URLSession HTTP, production SurgeModuleSanitizer, actual isolated JSC helper executing a fixed controlled transform, atomic cache and local output writes. Four concurrent jobs; one warmup then measured runs. Helper inputs are supplied as literals, so this is NOT a public-network Script-Hub end-to-end benchmark. No AppModel/UI/real GitHub publication or workspace files. RSS is aggregate parent+descendant 100ms sampled peak excluding the ps sampler, not instantaneous peak. CPU includes self and reaped children including sampling overhead. HTTP request count excludes warmup; stage bytes are content bytes, not protocol traffic. Cache hit means HTTP304; partial means HTTP503 on every fifth source, alternating available/missing cache.",
                            os: ProcessInfo.processInfo.operatingSystemVersionString, processorCount: ProcessInfo.processInfo.processorCount,
                            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, metricsEnabled: instrumented, inputBytesPerModule: body.count, cells: cells)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: output, options: .atomic)
    }
}
