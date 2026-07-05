import Foundation

struct SourceRevisionSnapshot: Sendable {
    var etag: String?
    var lastModified: String?
    var contentHash: String
    var checkedAt: Date
}

enum SourceRevisionResult: Sendable {
    case unchanged(SourceRevisionSnapshot)
    case changed(SourceRevisionSnapshot)
}
