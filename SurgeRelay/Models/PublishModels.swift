import Foundation

struct PublishFile: Sendable {
    var name: String
    var data: Data
}

struct PublishReport: Sendable {
    var publishedFiles: [String]
    var deletedFiles: [String] = []
    var commitSHA: String? = nil
    var retriedAfterConflict = false
    var baseCommitSHA: String? = nil
    var duration: TimeInterval = 0
    var stageMetrics: [StageMetric]? = nil

    var changedFileCount: Int {
        publishedFiles.count + deletedFiles.count
    }
}

enum PublishDestination: String, Codable, CaseIterable, Sendable {
    case local
    case gitHub

    var title: String {
        switch self {
        case .local: "本地"
        case .gitHub: "GitHub"
        }
    }
}

struct PublishPreview: Identifiable, Equatable, Encodable, Sendable {
    var id = UUID()
    var destination: PublishDestination
    var targetDescription: String
    var activeFiles: [String]
    var changedFiles: [String]
    var deletedFiles: [String]
    var issues: [ModuleLintIssue] = []
    var reviewToken: UUID? = nil
    var localExpectedHashes: [String: String]? = nil
    var localReviewFingerprint: String? = nil

    var changedFileCount: Int {
        changedFiles.count + deletedFiles.count
    }

    var hasChanges: Bool {
        changedFileCount > 0
    }

    var requiresDeletionConfirmation: Bool {
        !deletedFiles.isEmpty
    }
}

enum PublishTargetStatus: String, Codable, Sendable {
    case pending, succeeded, failed, cancelled, skipped
}

struct PublishTargetResult: Codable, Equatable, Sendable, Identifiable {
    var destination: PublishDestination
    var target: String
    var status: PublishTargetStatus = .pending
    var message = "等待发布"
    var publishedFiles: [String] = []
    var commitSHA: String?
    var id: PublishDestination { destination }
    var canRetry: Bool { status == .failed || status == .cancelled || status == .pending }
}

struct SelectedPublishAttempt: Codable, Equatable, Sendable {
    var id = UUID()
    var date = Date.now
    var moduleIDs: Set<UUID>
    var results: [PublishTargetResult]

    var retryDestinations: Set<PublishDestination> {
        Set(results.filter(\.canRetry).map(\.destination))
    }

    var succeeded: Bool {
        results.contains { $0.status == .succeeded } && retryDestinations.isEmpty
    }

    var summary: String {
        results.map { "\($0.destination.title)：\($0.message)" }.joined(separator: "；")
    }

    var restored: Self {
        var value = self
        for index in value.results.indices where value.results[index].status == .pending {
            value.results[index].status = .cancelled
            value.results[index].message = "上次发布中断，请核对后重试"
        }
        return value
    }
}

struct SelectedPublishLintReview: Identifiable {
    var id = UUID()
    var reviewToken: UUID
    var moduleIDs: Set<UUID>
    var issues: [ModuleLintIssue]
}
