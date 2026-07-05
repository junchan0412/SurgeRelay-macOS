(function installSurgeRelayWebLogic(global) {
  function failureSummary(message, maxLength = 42) {
    const firstLine = String(message || '').split(/\r?\n/)[0]?.replace(/\s+/g, ' ').trim() || '';
    if (firstLine.length <= maxLength) return firstLine;
    return `${firstLine.slice(0, Math.max(1, maxLength - 1))}…`;
  }

  function moduleListSignature(module) {
    return JSON.stringify([
      module.id, module.name, module.sourceURL, module.effectiveOriginalSourceURL,
      module.sourceFormatTitle, module.outputFolder, module.publishedRelativePath,
      module.storageLocation, module.storageLocationTitle, module.sourceOriginTitle,
      module.relationshipSummary, module.localStorageRelativePath,
      module.iconURL, module.customIconURL, module.isEnabled, module.publishesStandalone,
      module.state, module.stateTitle, module.lastError, module.lastUpdatedAt, module.sourceCheckedAt,
      module.contentHash, module.sourceContentHash, module.sourceETag, module.sourceLastModified,
      module.conversionEngineRevision
    ].map(value => String(value ?? '')));
  }

  function sidebarListSignature(snapshot) {
    return JSON.stringify([
      snapshot?.combined?.isEnabled ? 'combined-on' : 'combined-off',
      (snapshot?.modules || []).map(moduleListSignature)
    ]);
  }

  function metadataRowPresenceChanged(previousModule, nextModule) {
    if (!previousModule || !nextModule) return false;
    return Boolean(previousModule.sourceContentHash) !== Boolean(nextModule.sourceContentHash) ||
      Boolean(previousModule.sourceETag) !== Boolean(nextModule.sourceETag) ||
      Boolean(previousModule.sourceLastModified) !== Boolean(nextModule.sourceLastModified) ||
      previousModule.storageLocation !== nextModule.storageLocation ||
      previousModule.sourceOriginTitle !== nextModule.sourceOriginTitle ||
      previousModule.localStorageRelativePath !== nextModule.localStorageRelativePath ||
      previousModule.lastError !== nextModule.lastError;
  }

  function moduleSubtitle(module) {
    const parts = module.state === 'failed' && failureSummary(module.lastError)
      ? [`更新失败：${failureSummary(module.lastError)}`]
      : [module.relationshipSummary || module.sourceFormatTitle || '模块'];
    if (module.category) parts.push(module.category);
    if (module.outputFolder) parts.push(folderTitle(module.outputFolder));
    if (!module.publishesStandalone) parts.push('不发布独立模块');
    return parts.join(' · ');
  }

  function moduleStatusTitle(module) {
    const stateTitle = module.stateTitle || '状态未知';
    const summary = module.state === 'failed' ? failureSummary(module.lastError) : '';
    return summary ? `${stateTitle}：${summary}` : stateTitle;
  }

  function moduleSearchText(module) {
    return [
      module.name,
      module.sourceURL,
      module.effectiveOriginalSourceURL,
      module.sourceFormatTitle,
      module.sourceOriginTitle,
      module.storageLocationTitle,
      module.relationshipSummary,
      module.outputFileName,
      module.publishedRelativePath,
      module.category,
      module.outputFolder,
      module.iconURL,
      module.customIconURL,
      module.stateTitle,
      module.sourceContentHash,
      module.sourceETag,
      module.sourceLastModified,
      module.lastError,
      module.publishesStandalone ? '独立模块' : '不发布独立模块'
    ].map(value => String(value ?? '')).join('\n').toLocaleLowerCase();
  }

  function moduleMatchesSearch(module, query) {
    const normalizedQuery = String(query || '').trim().toLocaleLowerCase();
    return !normalizedQuery || moduleSearchText(module).includes(normalizedQuery);
  }

  function failedModuleCount(modules) {
    return (modules || []).filter(isFailedModule).length;
  }

  function sidebarFailureFilterState(modules, requestedFailuresOnly) {
    const failedCount = failedModuleCount(modules);
    return {
      failedCount,
      failuresOnly: failedCount > 0 && Boolean(requestedFailuresOnly),
      isVisible: failedCount > 0,
      label: `失败 ${failedCount}`
    };
  }

  function sidebarModules(modules, options = {}) {
    const failuresOnly = Boolean(options.failuresOnly);
    return (modules || []).filter(module =>
      (!failuresOnly || isFailedModule(module)) &&
      moduleMatchesSearch(module, options.query)
    );
  }

  function sidebarEmptyText(options = {}) {
    const hasQuery = String(options.query || '').trim().length > 0;
    if (hasQuery) return '没有搜索结果';
    return options.failuresOnly ? '没有更新失败的模块' : '还没有模块';
  }

  function isFailedModule(module) {
    return module?.state === 'failed';
  }

  function folderTitle(folder) {
    return folder ? folder : '根目录';
  }

  function publishedRelativePathForDraft(draft) {
    const folder = normalizeFolder(draft.outputFolder);
    const fileName = normalizedOutputFileName(draft);
    return [folder, fileName].filter(Boolean).join('/');
  }

  function outputPathNotice(path, publishesStandalone, context = {}) {
    if (!publishesStandalone) return { message: '未开启独立发布时，不会写出这个独立模块文件。', warning: false };
    const normalizedPath = String(path || '').toLowerCase();
    const combinedFile = sgmoduleName(context.combinedFileName || 'Surge Relay');
    if (normalizedPath === combinedFile.toLowerCase()) {
      return { message: '该路径与总模块文件冲突，保存时会自动加编号避免覆盖。', warning: true };
    }
    const editingID = context.editingID ?? null;
    const owner = (context.modules || []).find(module =>
      module.id !== editingID && String(module.publishedRelativePath || '').toLowerCase() === normalizedPath
    );
    if (owner) {
      return { message: `该路径已被“${owner.name}”使用，保存时会自动加编号避免覆盖。`, warning: true };
    }
    return null;
  }

  function normalizedOutputFileName(draft) {
    const sourceURL = String(draft.sourceURL || '');
    const explicit = String(draft.outputFileName || '').trim();
    const displayName = String(draft.name || '').trim();
    const preferred = explicit || displayName || suggestedNameFromSource(sourceURL);
    return isFileSource(sourceURL) || draft.storageLocation === 'local'
      ? existingSgmoduleName(preferred)
      : sgmoduleName(preferred);
  }

  function suggestedNameFromSource(sourceURL) {
    try {
      const url = new URL(sourceURL);
      const last = decodeURIComponent(url.pathname.split('/').filter(Boolean).pop() || '');
      return baseName(last);
    } catch {
      return '';
    }
  }

  function normalizeFolder(value) {
    return String(value || '')
      .replaceAll('\\', '/')
      .split('/')
      .map(part => part.trim())
      .filter(part => part && part !== '.' && part !== '..')
      .join('/');
  }

  function isFileSource(sourceURL) {
    try { return new URL(sourceURL).protocol === 'file:'; }
    catch { return false; }
  }

  function sgmoduleName(value) {
    const base = baseName(value);
    return `${base || 'Untitled'}.sgmodule`;
  }

  function existingSgmoduleName(value) {
    const base = existingFileBaseName(value);
    return `${base || 'Untitled'}.sgmodule`;
  }

  function baseName(value) {
    return String(value || '')
      .trim()
      .replace(/\.sgmodule$/i, '')
      .replace(/[\/\\:*?"<>|]+/g, '-')
      .replace(/\s+/g, '-')
      .replace(/^[.\-\s]+|[.\-\s]+$/g, '');
  }

  function existingFileBaseName(value) {
    const fileName = String(value || '').trim().replaceAll('\\', '/').split('/').pop() || '';
    return fileName
      .replace(/\.sgmodule$/i, '')
      .replace(/[:*?"<>|]+/g, '-')
      .replace(/^[.\s]+|[.\s]+$/g, '');
  }

  global.SurgeRelayWebLogic = {
    failureSummary,
    moduleListSignature,
    sidebarListSignature,
    metadataRowPresenceChanged,
    moduleSubtitle,
    moduleStatusTitle,
    moduleSearchText,
    moduleMatchesSearch,
    failedModuleCount,
    sidebarFailureFilterState,
    sidebarModules,
    sidebarEmptyText,
    folderTitle,
    publishedRelativePathForDraft,
    outputPathNotice,
    normalizedOutputFileName,
    suggestedNameFromSource,
    normalizeFolder,
    isFileSource,
    sgmoduleName,
    existingSgmoduleName,
    baseName,
    existingFileBaseName
  };
})(globalThis);
