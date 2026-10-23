import Foundation

enum LegacyOutputCleanupPlanner {
    static func cleanupDirectories(
        outputDirectory: String,
        configurationDirectory: String,
        localModuleDirectory: String
    ) -> [String] {
        let localRoot = LocalSourcePathResolver.canonicalDirectoryURL(for: localModuleDirectory)?.path
        var seen = Set<String>()
        return [outputDirectory, configurationDirectory].compactMap { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let standardized = LocalSourcePathResolver.canonicalDirectoryURL(for: trimmed)?.path else { return nil }
            guard standardized != localRoot, seen.insert(standardized).inserted else { return nil }
            return standardized
        }
    }

    static func publishedRelativePaths(
        combinedModuleFileName: String,
        managedEngineFileName: String
    ) -> [String] {
        [
            combinedModuleFileName,
            "Surge-Relay.sgmodule",
            managedEngineFileName,
            "Script-Hub-Relay.sgmodule"
        ].map(FilenameSanitizer.sgmoduleName(from:))
    }
}
