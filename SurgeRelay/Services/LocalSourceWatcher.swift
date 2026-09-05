import CoreServices
import Foundation

/// FSEvents C 回调与异步序列之间的桥接对象，由事件流按 `Unmanaged` 持有。
///
/// 刻意声明在文件作用域而不是嵌套在 `LocalSourceWatcher` 里：嵌套类型会继承外层
/// 的 `@MainActor` 隔离，而 FSEvents 回调运行在后台派发队列上，从那里读取
/// main-actor 隔离的属性会在运行时触发执行器断言而崩溃。
private final class LocalSourceEventSink: Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}

/// FSEvents 的 C 回调。
///
/// 必须是文件作用域函数而不是写在 `start(paths:latency:)` 里的闭包：闭包会继承
/// 方法的 `@MainActor` 隔离，Swift 6 会为此插入执行器断言，而回调运行在后台派发
/// 队列上，断言会直接 SIGTRAP。
private func localSourceEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numberOfEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    Unmanaged<LocalSourceEventSink>.fromOpaque(info)
        .takeUnretainedValue()
        .continuation
        .yield()
}

/// 用 FSEvents 递归监听本地模块来源目录，把合并后的改动通知投递到异步序列。
///
/// 这里没有为每个文件单独打开文件描述符：模块文件通常位于 iCloud Drive，
/// 原子替换和按需下载都会更换 inode，逐文件监听会在第一次保存后失效。
/// FSEvents 监听目录，可以稳定覆盖新增、替换、重命名和 iCloud 落地。
@MainActor
final class LocalSourceWatcher {
    private let queue = DispatchQueue(
        label: "com.allenmiao.SurgeRelay.local-source-watcher",
        qos: .utility
    )
    private var eventStream: FSEventStreamRef?
    private var sink: Unmanaged<LocalSourceEventSink>?
    private var continuation: AsyncStream<Void>.Continuation?
    private(set) var watchedPaths: [String] = []

    var isWatching: Bool { eventStream != nil }

    /// 当前监听集合是否已经等于 `paths`。
    func watches(_ paths: [String]) -> Bool {
        isWatching && watchedPaths == paths
    }

    /// 开始递归监听 `paths`。返回的序列在每一批文件事件后产生一个元素；
    /// 无法监听或路径为空时返回 nil。
    func start(paths: [String], latency: TimeInterval = 1.0) -> AsyncStream<Void>? {
        stop()
        guard !paths.isEmpty else { return nil }

        var createdStream: FSEventStreamRef?
        var createdSink: Unmanaged<LocalSourceEventSink>?
        let events = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let sink = Unmanaged.passRetained(LocalSourceEventSink(continuation: continuation))
            var context = FSEventStreamContext(
                version: 0,
                info: sink.toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            // kFSEventStreamCreateFlagIgnoreSelf 让 Surge Relay 自己写出的发布文件
            // 不再回灌成“来源已改动”，只保留其他进程（编辑器、iCloud、iOS 端）的改动。
            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents |
                    kFSEventStreamCreateFlagNoDefer |
                    kFSEventStreamCreateFlagIgnoreSelf
            )
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                localSourceEventCallback,
                &context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            ) else {
                sink.release()
                continuation.finish()
                return
            }
            createdStream = stream
            createdSink = sink
        }

        guard let stream = createdStream, let sink = createdSink else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            sink.takeUnretainedValue().continuation.finish()
            sink.release()
            return nil
        }
        eventStream = stream
        self.sink = sink
        continuation = sink.takeUnretainedValue().continuation
        watchedPaths = paths
        return events
    }

    /// 停止监听并结束当前序列。可以重复调用。
    func stop() {
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }
        eventStream = nil
        continuation?.finish()
        continuation = nil
        sink?.release()
        sink = nil
        watchedPaths = []
    }
}
