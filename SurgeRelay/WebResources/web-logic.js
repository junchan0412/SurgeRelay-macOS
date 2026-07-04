(function installSurgeRelayWebLogic(global) {
  function failureSummary(message, maxLength = 42) {
    const firstLine = String(message || '').split(/\r?\n/)[0]?.replace(/\s+/g, ' ').trim() || '';
    if (firstLine.length <= maxLength) return firstLine;
    return `${firstLine.slice(0, Math.max(1, maxLength - 1))}…`;
  }

  function moduleListSignature(module) {
    return [
      module.id, module.name, module.sourceURL, module.effectiveOriginalSourceURL,
      module.sourceFormatTitle, module.outputFolder, module.publishedRelativePath,
      module.storageLocation, module.storageLocationTitle, module.sourceOriginTitle,
      module.relationshipSummary, module.localStorageRelativePath,
      module.iconURL, module.customIconURL, module.isEnabled, module.publishesStandalone,
      module.state, module.stateTitle, module.lastError, module.lastUpdatedAt, module.sourceCheckedAt,
      module.contentHash, module.sourceContentHash, module.sourceETag, module.sourceLastModified,
      module.conversionEngineRevision
    ].map(value => String(value ?? '')).join('\u{1f}');
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
    moduleSubtitle,
    moduleStatusTitle,
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
