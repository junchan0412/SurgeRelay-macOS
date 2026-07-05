import Foundation

enum GitHubAPI {
    struct ExistingContent: Decodable {
        let sha: String
    }

    struct Message: Decodable {
        let message: String
    }

    struct RepositoryMetadata: Decodable {
        let isPrivate: Bool

        private enum CodingKeys: String, CodingKey {
            case isPrivate = "private"
        }
    }

    struct Object: Codable {
        let sha: String
    }

    struct ReferenceResponse: Decodable {
        let object: Object
    }

    struct CommitResponse: Decodable {
        let sha: String
        let tree: Object
    }

    struct TreeItem: Decodable {
        let path: String
        let type: String
        let sha: String?
    }

    struct RecursiveTreeResponse: Decodable {
        let tree: [TreeItem]
        let truncated: Bool?
    }

    struct BlobRequest: Encodable {
        let content: String
        let encoding = "base64"
    }

    struct BlobResponse: Decodable {
        let sha: String
    }

    struct TreeEntry: Encodable {
        let path: String
        let mode: String?
        let type: String?
        let sha: String?

        init(path: String, sha: String) {
            self.path = path
            mode = "100644"
            type = "blob"
            self.sha = sha
        }

        init(deletingPath path: String) {
            self.path = path
            mode = nil
            type = nil
            sha = nil
        }

        private enum CodingKeys: String, CodingKey {
            case path, mode, type, sha
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(mode, forKey: .mode)
            try container.encodeIfPresent(type, forKey: .type)
            if let sha {
                try container.encode(sha, forKey: .sha)
            } else {
                try container.encodeNil(forKey: .sha)
            }
        }
    }

    struct TreeRequest: Encodable {
        let baseTree: String
        let tree: [TreeEntry]

        private enum CodingKeys: String, CodingKey {
            case baseTree = "base_tree"
            case tree
        }
    }

    struct TreeResponse: Decodable {
        let sha: String
    }

    struct CommitRequest: Encodable {
        let message: String
        let tree: String
        let parents: [String]
    }

    struct UpdateReferenceRequest: Encodable {
        let sha: String
        let force = false
    }
}
