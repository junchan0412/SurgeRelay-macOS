import Foundation

enum LegacyOutputCleanupPlanner {
    static func cleanupDirectories(
        outputDirectory: String,
        configurationDirectory: String,
        localModuleDirectory: String
    ) -> [String] {
        let localRoot = URL(filePath: localModuleDirectory, directoryHint: .isDirectory)
            .standardizedFileURL
            .path
        var seen = Set<String>()
        return [outputDirectory, configurationDirectory].compactMap { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let standardized = URL(filePath: trimmed, directoryHint: .isDirectory).standardizedFileURL.path
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
