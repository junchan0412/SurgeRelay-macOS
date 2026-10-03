import Foundation

enum ModuleTemplatePlanner {
    static func template(from module: RelayModule, name: String) throws -> ModuleTemplate {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RelayError.invalidOutput("请输入模板名称。") }
        let source = module.scriptHubOptions
        var options = ScriptHubOptions()
        options.scriptConversionKeywords = source.scriptConversionKeywords
        options.convertAllScripts = source.convertAllScripts
        options.responseScriptConversionKeywords = source.responseScriptConversionKeywords
        options.convertAllResponseScripts = source.convertAllResponseScripts
        options.compatibilityOnly = source.compatibilityOnly
        options.includeKeywords = source.includeKeywords
        options.excludeKeywords = source.excludeKeywords
        options.syncMITMToForceHTTP = source.syncMITMToForceHTTP
        options.removeCommentedRewrites = source.removeCommentedRewrites
        options.keepMapLocalHeaders = source.keepMapLocalHeaders
        options.useJSDelivr = source.useJSDelivr
        options.policy = source.policy
        options.mitmAdd = source.mitmAdd
        options.mitmRemove = source.mitmRemove
        options.mitmRemoveRegex = source.mitmRemoveRegex
        options.scriptNameTargets = source.scriptNameTargets
        options.scriptNames = source.scriptNames
        options.timeoutTargets = source.timeoutTargets
        options.timeoutValues = source.timeoutValues
        options.engineTargets = source.engineTargets
        options.engineValues = source.engineValues
        options.cronTargets = source.cronTargets
        options.cronExpressions = source.cronExpressions
        options.noResolve = source.noResolve
        options.sniKeywords = source.sniKeywords
        options.preMatchingKeywords = source.preMatchingKeywords
        options.enableJQ = source.enableJQ
        return ModuleTemplate(name: name, sourceFormat: module.sourceFormat, category: module.category,
                              moduleDescription: module.moduleDescription, outputFolder: module.outputFolder,
                              storageTargets: module.storageTargets, publishesStandalone: module.publishesStandalone,
                              isIncludedInCombined: module.isIncludedInCombined, refreshIntervalMinutes: module.refreshIntervalMinutes,
                              scriptHubOptions: options)
    }

    static func draft(from template: ModuleTemplate) -> ModuleDraft {
        var draft = ModuleDraft()
        draft.name = template.name
        draft.sourceFormat = template.sourceFormat
        draft.category = template.category
        draft.moduleDescription = template.moduleDescription
        draft.outputFolder = template.outputFolder
        draft.storageTargets = template.storageTargets
        draft.publishesStandalone = template.publishesStandalone
        draft.isEnabled = template.isIncludedInCombined
        draft.refreshIntervalMinutes = template.refreshIntervalMinutes
        draft.scriptHubOptions = template.scriptHubOptions
        return draft
    }
}
