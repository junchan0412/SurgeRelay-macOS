import Foundation

struct ModuleTemplate: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var sourceFormat: ModuleSourceFormat
    var category: String
    var moduleDescription: String
    var outputFolder: String
    var storageTargets: Set<ModuleStorageLocation>
    var publishesStandalone: Bool
    var isIncludedInCombined: Bool
    var refreshIntervalMinutes: Int?
    var scriptHubOptions: ScriptHubOptions
}
