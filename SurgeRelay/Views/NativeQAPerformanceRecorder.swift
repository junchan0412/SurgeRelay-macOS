import AppKit
import QuartzCore
import Darwin

struct NativeQAInputUpdate: Encodable, Equatable, Sendable {
    var groupedEventCount: Int
    var nonTextKeyDownCount: Int
    var textChangeNotificationCount: Int
    var documentUTF16Count: Int
    var keyDownToAppKitUpdateMilliseconds: [Double]
    var eventTimestampToAppKitUpdateMilliseconds: [Double?]
    var textChangeToAppKitUpdateMilliseconds: [Double]
}

struct NativeQAInputAccumulator {
    private struct Event {
        var receivedAt: TimeInterval
        var eventTimestamp: TimeInterval?
        var textChangedAt: TimeInterval?
    }
    private var events: [Event] = []
    private var textChanges = 0
    private var documentUTF16Count = 0

    mutating func keyDown(at time: TimeInterval, eventTimestamp: TimeInterval?) {
        let timestamp = eventTimestamp.flatMap { $0.isFinite && $0 > 0 && $0 <= time ? $0 : nil }
        events.append(Event(receivedAt: time, eventTimestamp: timestamp))
    }

    mutating func textChanged(at time: TimeInterval, documentUTF16Count: Int) {
        guard !events.isEmpty else { return }
        if events[events.count - 1].textChangedAt == nil { events[events.count - 1].textChangedAt = time }
        textChanges += 1
        self.documentUTF16Count = documentUTF16Count
    }

    mutating func appKitUpdated(at time: TimeInterval) -> NativeQAInputUpdate? {
        let changed = events.filter { $0.textChangedAt != nil }
        defer { events.removeAll(keepingCapacity: true); textChanges = 0 }
        guard !changed.isEmpty else { return nil }
        return NativeQAInputUpdate(
            groupedEventCount: changed.count,
            nonTextKeyDownCount: events.count - changed.count,
            textChangeNotificationCount: textChanges,
            documentUTF16Count: documentUTF16Count,
            keyDownToAppKitUpdateMilliseconds: changed.map { max(0, time - $0.receivedAt) * 1000 },
            eventTimestampToAppKitUpdateMilliseconds: changed.map { event in event.eventTimestamp.map { max(0, time - $0) * 1000 } },
            textChangeToAppKitUpdateMilliseconds: changed.map { max(0, time - ($0.textChangedAt ?? time)) * 1000 }
        )
    }
}

struct NativeQAFrameCadence {
    private var previous: (time: Double, nominal: Double, eligible: Bool)?

    mutating func reset() { previous = nil }

    mutating func observe(time: Double, nominal: Double, eligible: Bool) -> (interval: Double?, missedEstimate: Int?) {
        guard time.isFinite else { reset(); return (nil, nil) }
        defer { previous = (time, nominal, eligible) }
        guard let previous, time >= previous.time else { return (nil, nil) }
        let interval = time - previous.time
        guard eligible, previous.eligible, nominal.isFinite, nominal > 0,
              previous.nominal.isFinite, previous.nominal > 0,
              abs(nominal - previous.nominal) <= nominal * 0.05 else { return (interval, nil) }
        let slots = (interval / nominal).rounded()
        guard slots.isFinite, slots < Double(Int.max) else { return (interval, nil) }
        return (interval, max(0, Int(slots) - 1))
    }
}

private final class NativeQARSSSampler: @unchecked Sendable {
    struct Snapshot: Sendable {
        var uptimeSeconds: Double = 0
        var residentBytes: UInt64?
        var sampledPeakBytes: UInt64 = 0
        var sampleCount = 0
    }
    private let lock = NSLock()
    private var latest = Snapshot()
    func sample() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let bytes = result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
        lock.lock()
        latest.uptimeSeconds = ProcessInfo.processInfo.systemUptime
        latest.residentBytes = bytes
        latest.sampledPeakBytes = max(latest.sampledPeakBytes, bytes ?? 0)
        latest.sampleCount += 1
        lock.unlock()
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return latest
    }
}

@MainActor
final class NativeQAPerformanceRecorder: NSObject {
    static let outputEnvironmentKey = "SURGE_RELAY_UI_QA_INPUT_OUTPUT"
    static let shared: NativeQAPerformanceRecorder? = {
        guard let output = outputURL(environment: ProcessInfo.processInfo.environment) else { return nil }
        do { return try NativeQAPerformanceRecorder(outputURL: output) }
        catch { NSLog("Native QA input recording could not start: %@", error.localizedDescription); return nil }
    }()

    static func outputURL(environment: [String: String]) -> URL? {
        guard environment["SURGE_RELAY_UI_QA"] == "1",
              let path = environment[outputEnvironmentKey], path.hasPrefix("/"), !path.hasSuffix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func framesEnabled(environment: [String: String]) -> Bool {
        environment["SURGE_RELAY_UI_QA_FRAMES"] == "1" && outputURL(environment: environment) != nil
    }

    static func startAtApplicationLaunch() {
        guard framesEnabled(environment: ProcessInfo.processInfo.environment) else { return }
        shared?.startFrameSampling()
    }

    private struct Session: Encodable {
        let type = "session"
        let schemaVersion = 1
        var sessionID: String
        var processID: Int32
        var executablePath: String
        var bundleIdentifier: String?
        var wallTimeEpochSeconds: Double
        var uptimeSeconds: Double
        let boundary = "keyDown entry / text change -> NSApplication.didUpdateNotification; not GPU presentation or FPS"
        let phaseBoundary = "Main-thread synchronous phase totals between didUpdate notifications; nested phases overlap and must not be summed. Phase-only updates are retained without tracked input."
        let eventTimestampBoundary = "NSEvent timestamp -> NSApplication.didUpdateNotification; includes event delivery delay when timestamp is available"
        let frameBoundary = "CADisplayLink on main RunLoop.common, running only while application active and window visible, occlusion-visible and not miniaturized: actual callback interval, NOT GPU presentation FPS. Missed cadence is an estimate based on stable target period; filter visibility/activity and link resets. RSS remains host task_info at background 1Hz with bounded latest/peak storage, not app+helper footprint."
        let recordingBounds = "At most 4 queued write batches; 64 MiB output-file budget. Dropped batches/bytes are cumulative in frame records."
        let excludes = "No text, key code, characters, document path or selection content is recorded. Input-update excludes non-text key groups and changes without a tracked keyDown; phase-update also records windows without input."
    }
    private struct Record: Encodable {
        let type = "input-update"
        var sessionID: String
        var sequence: Int
        var updateSequence: Int
        var uptimeSeconds: TimeInterval
        var sample: NativeQAInputUpdate
    }
    private struct FrameRecord: Encodable {
        let type = "frame-callback"
        var sessionID: String
        var uptimeSeconds: Double
        var callbackIntervalMilliseconds: Double?
        var nominalDurationMilliseconds: Double?
        var targetPeriodMilliseconds: Double?
        var displayTimestamp: Double?
        var displayTargetTimestamp: Double?
        var missedCadenceEstimate: Int?
        var cadenceEligible: Bool
        var windowNumber: Int?
        var windowVisible: Bool
        var windowOcclusionVisible: Bool
        var windowMiniaturized: Bool
        var windowIsMain: Bool
        var applicationActive: Bool
        var droppedWriteBatches: Int
        var droppedWriteBytes: Int
    }
    private struct RSSRecord: Encodable {
        let type = "rss-sample"
        var sessionID: String
        var uptimeSeconds: Double
        var emittedAtUptimeSeconds: Double
        var residentBytes: UInt64?
        var sampledPeakBytes: UInt64
        var sampleCount: Int
    }

    private struct PhaseStatistics: Encodable {
        var count = 0
        var totalMilliseconds: Double = 0
        var maxMilliseconds: Double = 0
    }
    private struct PhaseRecord: Encodable {
        let type = "phase-update"
        var sessionID: String
        var updateSequence: Int
        var uptimeSeconds: TimeInterval
        var intervalStartUptimeSeconds: TimeInterval
        var hadTrackedInput: Bool
        var attributedUnionMilliseconds: Double
        var phases: [String: PhaseStatistics]
    }

    private struct GeometryRecord: Encodable {
        let type = "editor-geometry"
        var sessionID: String
        var updateSequence: Int
        var uptimeSeconds: TimeInterval
        var width: Double?
        var widthDescription: String
        var bounds: [Double?]
        var textStorageLength: Int?
        var isPlainTextMode: Bool
        var cachedPlainTextSize: [Double?]?
        var hasTextContainer: Bool
        var cachedPlainLineCount: Int?
    }

    func recordGeometry(width: CGFloat, bounds: NSRect, textStorageLength: Int?, isPlainTextMode: Bool,
                        cachedPlainTextSize: CGSize?, hasTextContainer: Bool, cachedPlainLineCount: Int?) {
        guard !stopped else { return }
        func finite(_ value: CGFloat) -> Double? { value.isFinite ? Double(value) : nil }
        append(GeometryRecord(sessionID: sessionID, updateSequence: updateSequence + 1,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime, width: finite(width), widthDescription: String(describing: width),
            bounds: [bounds.minX, bounds.minY, bounds.width, bounds.height].map(finite),
            textStorageLength: textStorageLength, isPlainTextMode: isPlainTextMode,
            cachedPlainTextSize: cachedPlainTextSize.map { [finite($0.width), finite($0.height)] },
            hasTextContainer: hasTextContainer, cachedPlainLineCount: cachedPlainLineCount))
    }

    static func measure<Value>(_ name: String, _ operation: () throws -> Value) rethrows -> Value {
        guard let recorder = shared, !recorder.stopped else { return try operation() }
        let started = ProcessInfo.processInfo.systemUptime
        recorder.phaseDepth += 1
        defer {
            recorder.phaseDepth -= 1
            recorder.recordPhase(name, started: started, isOutermost: recorder.phaseDepth == 0)
        }
        return try operation()
    }

    private func recordPhase(_ name: String, started: TimeInterval, isOutermost: Bool) {
        guard !stopped else { return }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started) * 1000
        if isOutermost { attributedUnionMilliseconds += elapsed }
        phaseIntervalStartedAt = min(phaseIntervalStartedAt ?? started, started)
        var statistics = phases[name, default: PhaseStatistics()]
        statistics.count += 1
        statistics.totalMilliseconds += elapsed
        statistics.maxMilliseconds = max(statistics.maxMilliseconds, elapsed)
        phases[name] = statistics
    }

    private let sessionID = UUID().uuidString
    private let handle: FileHandle
    private let ioQueue = DispatchQueue(label: "SurgeRelay.NativeQAInputRecorder", qos: .utility)
    private var pending: [ObjectIdentifier: NativeQAInputAccumulator] = [:]
    private var buffer = Data()
    private var flushWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var sequence = 0
    private var updateSequence = 0
    private var phases: [String: PhaseStatistics] = [:]
    private var phaseIntervalStartedAt: TimeInterval?
    private var phaseDepth = 0
    private var attributedUnionMilliseconds: Double = 0
    private var stopped = false
    private var displayLink: CADisplayLink?
    private weak var sampledWindow: NSWindow?
    private var frameCadence = NativeQAFrameCadence()
    private var rssTimer: DispatchSourceTimer?
    private let rssSampler = NativeQARSSSampler()
    private var lastRSSSampleCount = 0
    private let writeSlots = DispatchSemaphore(value: 4)
    private var droppedWriteBatches = 0
    private var droppedWriteBytes = 0
    private var reservedOutputBytes: UInt64 = 0
    private var outputLimitReached = false
    private let maximumOutputBytes: UInt64 = 64 * 1024 * 1024


    private init(outputURL: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: outputURL.path) {
            guard manager.createFile(atPath: outputURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let openedHandle = try FileHandle(forWritingTo: outputURL)
        handle = openedHandle
        reservedOutputBytes = try openedHandle.seekToEnd()
        super.init()
        guard reservedOutputBytes < maximumOutputBytes - 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        let sessionWallTime = Date().timeIntervalSince1970
        let sessionUptime = ProcessInfo.processInfo.systemUptime
        append(Session(sessionID: sessionID, processID: ProcessInfo.processInfo.processIdentifier,
                       executablePath: Bundle.main.executableURL?.path ?? "unknown", bundleIdentifier: Bundle.main.bundleIdentifier,
                       wallTimeEpochSeconds: sessionWallTime, uptimeSeconds: sessionUptime))
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appKitUpdated() }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            })
    }

    private func startFrameSampling() {
        guard displayLink == nil, rssTimer == nil, !stopped, !outputLimitReached else { return }
        let names: [Notification.Name] = [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
            NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.frameCadence.reset()
                    self?.refreshDisplayLink()
                }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.frameCadence.reset() }
            })
        }
        let sampler = rssSampler
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "SurgeRelay.NativeQA.RSS", qos: .utility))
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(50))
        timer.setEventHandler { @Sendable [sampler] in sampler.sample() }
        rssTimer = timer
        timer.resume()
        refreshDisplayLink()
    }

    private func refreshDisplayLink() {
        guard !stopped, !outputLimitReached else { return }
        let window = NSApp.mainWindow ?? NSApp.windows.first { $0.canBecomeMain && $0.isVisible }
        let shouldPause = !NSApp.isActive || window?.isVisible != true
            || window?.occlusionState.contains(.visible) != true || window?.isMiniaturized != false
        if let displayLink, sampledWindow === window {
            displayLink.isPaused = shouldPause
            return
        }
        displayLink?.invalidate()
        sampledWindow = window
        frameCadence.reset()
        if let window { displayLink = window.displayLink(target: self, selector: #selector(frameCallback(_:))) }
        else { displayLink = NSScreen.main?.displayLink(target: self, selector: #selector(frameCallback(_:))) }
        displayLink?.isPaused = shouldPause
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func frameCallback(_ link: CADisplayLink) {
        guard !stopped, !outputLimitReached else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let window = sampledWindow
        let visible = window?.isVisible ?? false
        let occlusionVisible = window?.occlusionState.contains(.visible) ?? false
        let miniaturized = window?.isMiniaturized ?? false
        let active = NSApp.isActive
        let eligible = visible && occlusionVisible && !miniaturized && active
        let targetPeriod = link.targetTimestamp - link.timestamp
        let budget = targetPeriod.isFinite && targetPeriod > 0 ? targetPeriod : link.duration
        let sample = frameCadence.observe(time: now, nominal: budget, eligible: eligible)
        func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
        append(FrameRecord(sessionID: sessionID, uptimeSeconds: now,
            callbackIntervalMilliseconds: sample.interval.map { $0 * 1000 },
            nominalDurationMilliseconds: finite(link.duration * 1000), targetPeriodMilliseconds: finite(targetPeriod * 1000),
            displayTimestamp: finite(link.timestamp), displayTargetTimestamp: finite(link.targetTimestamp),
            missedCadenceEstimate: sample.missedEstimate, cadenceEligible: eligible,
            windowNumber: window?.windowNumber, windowVisible: visible, windowOcclusionVisible: occlusionVisible,
            windowMiniaturized: miniaturized, windowIsMain: window?.isMainWindow ?? false, applicationActive: active,
            droppedWriteBatches: droppedWriteBatches, droppedWriteBytes: droppedWriteBytes))
        emitRSS(at: now)
    }

    private func emitRSS(at now: Double) {
        let sample = rssSampler.snapshot()
        guard sample.sampleCount > lastRSSSampleCount else { return }
        lastRSSSampleCount = sample.sampleCount
        append(RSSRecord(sessionID: sessionID, uptimeSeconds: sample.uptimeSeconds, emittedAtUptimeSeconds: now,
            residentBytes: sample.residentBytes, sampledPeakBytes: sample.sampledPeakBytes, sampleCount: sample.sampleCount))
    }

    func keyDown(in view: NSTextView, eventTimestamp: TimeInterval) {
        guard !stopped, view.isEditable else { return }
        pending[ObjectIdentifier(view), default: NativeQAInputAccumulator()]
            .keyDown(at: ProcessInfo.processInfo.systemUptime, eventTimestamp: eventTimestamp)
    }

    func textChanged(in view: NSTextView) {
        guard !stopped, pending[ObjectIdentifier(view)] != nil else { return }
        pending[ObjectIdentifier(view)]?.textChanged(at: ProcessInfo.processInfo.systemUptime,
            documentUTF16Count: view.textStorage?.length ?? (view.string as NSString).length)
    }

    private func appKitUpdated() {
        guard !stopped, !pending.isEmpty || !phases.isEmpty else { return }
        let time = ProcessInfo.processInfo.systemUptime
        updateSequence += 1
        var batches = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        let completedPhases = phases
        let completedUnionMilliseconds = attributedUnionMilliseconds
        attributedUnionMilliseconds = 0
        let phaseStart = phaseIntervalStartedAt ?? time
        phases.removeAll(keepingCapacity: true)
        phaseIntervalStartedAt = nil
        var hadTrackedInput = false
        for index in batches.indices {
            guard let sample = batches[index].appKitUpdated(at: time) else { continue }
            hadTrackedInput = true
            sequence += 1
            append(Record(sessionID: sessionID, sequence: sequence, updateSequence: updateSequence,
                          uptimeSeconds: time, sample: sample))
        }
        if !completedPhases.isEmpty {
            append(PhaseRecord(sessionID: sessionID, updateSequence: updateSequence, uptimeSeconds: time,
                intervalStartUptimeSeconds: phaseStart, hadTrackedInput: hadTrackedInput,
                attributedUnionMilliseconds: completedUnionMilliseconds, phases: completedPhases))
        }
    }

    private func append<Value: Encodable>(_ value: Value) {
        guard !outputLimitReached, let data = try? JSONEncoder().encode(value) else { return }
        if reservedOutputBytes + UInt64(buffer.count + data.count + 1) > maximumOutputBytes - 1024 {
            outputLimitReached = true
            displayLink?.invalidate()
            rssTimer?.cancel()
            buffer.append(Data("{\"type\":\"capture-limit\",\"reason\":\"64 MiB output budget reached\"}\n".utf8))
            flush()
            return
        }
        buffer.append(data)
        buffer.append(0x0A)
        if buffer.count >= 16 * 1024 { flush() }
        else if flushWorkItem == nil {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
            flushWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
        }
    }

    private func flush() {
        flushWorkItem?.cancel(); flushWorkItem = nil
        guard !buffer.isEmpty else { return }
        let data = buffer
        buffer.removeAll(keepingCapacity: true)
        guard writeSlots.wait(timeout: .now()) == .success else {
            droppedWriteBatches += 1
            droppedWriteBytes += data.count
            return
        }
        reservedOutputBytes += UInt64(data.count)
        let output = handle
        let slots = writeSlots
        ioQueue.async {
            defer { slots.signal() }
            do { try output.write(contentsOf: data) }
            catch { NSLog("Native QA input recording write failed: %@", error.localizedDescription) }
        }
    }

    private func finish() {
        guard !stopped else { return }
        displayLink?.invalidate()
        displayLink = nil
        rssTimer?.cancel()
        rssTimer = nil
        if Self.framesEnabled(environment: ProcessInfo.processInfo.environment) { emitRSS(at: ProcessInfo.processInfo.systemUptime) }
        stopped = true
        pending.removeAll()
        flush()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        let output = handle
        ioQueue.sync {
            try? output.synchronize()
            try? output.close()
        }
    }
}
