import Foundation

enum ConversionToolKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ruleSet
    case script

    var id: String { rawValue }
    var title: String { self == .ruleSet ? "规则集" : "独立脚本" }
}

enum RuleOutputStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case ruleSet
    case domainSet
    case nonDomainRules

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ruleSet: "规则集"
        case .domainSet: "域名集"
        case .nonDomainRules: "非域名剩余规则"
        }
    }
}

struct ConversionToolDraft: Codable, Equatable, Sendable {
    var kind: ConversionToolKind = .ruleSet
    var sourceURL = ""
    var sourceText = ""
    var outputName = "Converted"
    var outputFormat: ModuleOutputFormat = .surge
    var sourceFormat: ModuleSourceFormat = .quantumultX
    var ruleOutputStyle: RuleOutputStyle = .ruleSet
    var policy = "REJECT"
    var includeKeywords = ""
    var excludeKeywords = ""
    var requestHeaders = ""
    var noResolve = false
    var sni = ""
    var compatibilityOnly = false
    var wrapResponse = false
    var prependScript = ""
    var evalScriptOriginal = ""
    var evalScriptModified = ""
    var evalURLOriginal = ""
    var evalURLModified = ""

    private enum CodingKeys: String, CodingKey {
        case kind, sourceURL, sourceText, outputName, outputFormat, sourceFormat, ruleOutputStyle, policy
        case includeKeywords, excludeKeywords, requestHeaders, noResolve, sni
        case compatibilityOnly, wrapResponse, prependScript
        case evalScriptOriginal, evalScriptModified, evalURLOriginal, evalURLModified
    }
}

extension ConversionToolDraft {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decodeIfPresent(ConversionToolKind.self, forKey: .kind) ?? kind
        sourceURL = try values.decodeIfPresent(String.self, forKey: .sourceURL) ?? sourceURL
        sourceText = try values.decodeIfPresent(String.self, forKey: .sourceText) ?? sourceText
        outputName = try values.decodeIfPresent(String.self, forKey: .outputName) ?? outputName
        outputFormat = try values.decodeIfPresent(ModuleOutputFormat.self, forKey: .outputFormat) ?? outputFormat
        sourceFormat = try values.decodeIfPresent(ModuleSourceFormat.self, forKey: .sourceFormat) ?? sourceFormat
        ruleOutputStyle = try values.decodeIfPresent(RuleOutputStyle.self, forKey: .ruleOutputStyle) ?? ruleOutputStyle
        policy = try values.decodeIfPresent(String.self, forKey: .policy) ?? policy
        includeKeywords = try values.decodeIfPresent(String.self, forKey: .includeKeywords) ?? includeKeywords
        excludeKeywords = try values.decodeIfPresent(String.self, forKey: .excludeKeywords) ?? excludeKeywords
        requestHeaders = try values.decodeIfPresent(String.self, forKey: .requestHeaders) ?? requestHeaders
        noResolve = try values.decodeIfPresent(Bool.self, forKey: .noResolve) ?? noResolve
        sni = try values.decodeIfPresent(String.self, forKey: .sni) ?? sni
        compatibilityOnly = try values.decodeIfPresent(Bool.self, forKey: .compatibilityOnly) ?? compatibilityOnly
        wrapResponse = try values.decodeIfPresent(Bool.self, forKey: .wrapResponse) ?? wrapResponse
        prependScript = try values.decodeIfPresent(String.self, forKey: .prependScript) ?? prependScript
        evalScriptOriginal = try values.decodeIfPresent(String.self, forKey: .evalScriptOriginal) ?? evalScriptOriginal
        evalScriptModified = try values.decodeIfPresent(String.self, forKey: .evalScriptModified) ?? evalScriptModified
        evalURLOriginal = try values.decodeIfPresent(String.self, forKey: .evalURLOriginal) ?? evalURLOriginal
        evalURLModified = try values.decodeIfPresent(String.self, forKey: .evalURLModified) ?? evalURLModified
    }
}

struct ConversionToolResult: Encodable, Sendable {
    var fileName: String
    var content: String
    var outputFormat: ModuleOutputFormat
    var kind: ConversionToolKind
}
