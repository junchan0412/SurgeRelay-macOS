import Foundation

actor GitHubReleaseClient {
    static let latestReleaseAPIURL = URL(
        string: "https://api.github.com/repos/junchan0412/SurgeRelay-macOS/releases/latest"
    )!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestReleaseAPIURL, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SurgeRelay/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = String(data: data, encoding: .utf8) ?? "GitHub Release 查询失败。"
            throw RelayError.httpFailure(status: status, message: String(message.prefix(240)))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubRelease.self, from: data)
        return await releaseWithChecksumValidations(release)
    }

    private func releaseWithChecksumValidations(_ release: GitHubRelease) async -> GitHubRelease {
        var validated = release
        for asset in release.installableAssets {
            validated.checksumValidations[asset.name] = await checksumValidation(for: asset, in: release)
        }
        return validated
    }

    private func checksumValidation(
        for asset: GitHubReleaseAsset,
        in release: GitHubRelease
    ) async -> ReleaseAssetChecksumValidation {
        guard let checksum = release.checksumAsset(for: asset) else {
            return ReleaseAssetChecksumValidation(status: .missingChecksum)
        }
        guard let digestHash = asset.sha256Digest else {
            return ReleaseAssetChecksumValidation(status: .missingDigest)
        }

        do {
            var request = URLRequest(url: checksum.downloadURL, timeoutInterval: 15)
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
            request.setValue("SurgeRelay/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status),
                  let checksumHash = Self.sha256Hash(inChecksumText: String(decoding: data, as: UTF8.self)) else {
                return ReleaseAssetChecksumValidation(status: .unreadable, digestHash: digestHash)
            }
            return ReleaseAssetChecksumValidation(
                status: checksumHash == digestHash ? .matched : .mismatched,
                checksumHash: checksumHash,
                digestHash: digestHash
            )
        } catch {
            return ReleaseAssetChecksumValidation(status: .unreadable, digestHash: digestHash)
        }
    }

    private static func sha256Hash(inChecksumText text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace })
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
