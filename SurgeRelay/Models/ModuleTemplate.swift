import Foundation

struct ModuleTemplate: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var sourceFormat: ModuleSourceFormat
    var outputFormat: ModuleOutputFormat = .surge
    var category: String
    var moduleDescription: String
    var outputFolder: String
    var storageTargets: Set<ModuleStorageLocation>
    var refreshIntervalMinutes: Int?
    var scriptHubOptions: ScriptHubOptions

    private enum CodingKeys: String, CodingKey {
        case id, name, sourceFormat, outputFormat, category, moduleDescription, outputFolder
        case storageTargets, refreshIntervalMinutes, scriptHubOptions
    }

    init(id: UUID = UUID(), name: String, sourceFormat: ModuleSourceFormat, outputFormat: ModuleOutputFormat = .surge,
         category: String, moduleDescription: String, outputFolder: String,
         storageTargets: Set<ModuleStorageLocation>, refreshIntervalMinutes: Int?, scriptHubOptions: ScriptHubOptions) {
        self.id = id
        self.name = name
        self.sourceFormat = sourceFormat
        self.outputFormat = outputFormat
        self.category = category
        self.moduleDescription = moduleDescription
        self.outputFolder = outputFolder
        self.storageTargets = storageTargets
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.scriptHubOptions = scriptHubOptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourceFormat = try container.decode(ModuleSourceFormat.self, forKey: .sourceFormat)
        outputFormat = try container.decodeIfPresent(ModuleOutputFormat.self, forKey: .outputFormat) ?? .surge
        category = try container.decode(String.self, forKey: .category)
        moduleDescription = try container.decode(String.self, forKey: .moduleDescription)
        outputFolder = try container.decode(String.self, forKey: .outputFolder)
        storageTargets = try container.decode(Set<ModuleStorageLocation>.self, forKey: .storageTargets)
        refreshIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes)
        scriptHubOptions = try container.decode(ScriptHubOptions.self, forKey: .scriptHubOptions)
    }
}
