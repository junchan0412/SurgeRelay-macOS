import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const logicSource = readFileSync(new URL('../SurgeRelay/WebResources/web-logic.js', import.meta.url), 'utf8');
const optionsSource = readFileSync(new URL('../SurgeRelay/WebResources/web-options.js', import.meta.url), 'utf8');
const formatSource = readFileSync(new URL('../SurgeRelay/WebResources/web-format.js', import.meta.url), 'utf8');
const markupSource = readFileSync(new URL('../SurgeRelay/WebResources/web-markup.js', import.meta.url), 'utf8');
const apiSource = readFileSync(new URL('../SurgeRelay/WebResources/web-api.js', import.meta.url), 'utf8');
const stateSource = readFileSync(new URL('../SurgeRelay/WebResources/web-state.js', import.meta.url), 'utf8');
const editorSource = readFileSync(new URL('../SurgeRelay/WebResources/web-editor.js', import.meta.url), 'utf8');
const feedbackSource = readFileSync(new URL('../SurgeRelay/WebResources/web-feedback.js', import.meta.url), 'utf8');
const previewSource = readFileSync(new URL('../SurgeRelay/WebResources/web-preview.js', import.meta.url), 'utf8');
const appSource = readFileSync(new URL('../SurgeRelay/WebResources/app.js', import.meta.url), 'utf8');
const context = vm.createContext({ console, URL });
vm.runInContext(logicSource, context, { filename: 'web-logic.js' });
vm.runInContext(optionsSource, context, { filename: 'web-options.js' });
vm.runInContext(formatSource, context, { filename: 'web-format.js' });
vm.runInContext(markupSource, context, { filename: 'web-markup.js' });
vm.runInContext(apiSource, context, { filename: 'web-api.js' });
vm.runInContext(stateSource, context, { filename: 'web-state.js' });
vm.runInContext(editorSource, context, { filename: 'web-editor.js' });
vm.runInContext(feedbackSource, context, { filename: 'web-feedback.js' });
vm.runInContext(previewSource, context, { filename: 'web-preview.js' });

const logic = context.SurgeRelayWebLogic;
assert.ok(logic, 'web logic should install a global testable API');
const options = context.SurgeRelayWebOptions;
assert.ok(options, 'web options should install a global testable API');
const format = context.SurgeRelayWebFormat;
assert.ok(format, 'web format should install a global testable API');
const markup = context.SurgeRelayWebMarkup;
assert.ok(markup, 'web markup should install a global testable API');
const api = context.SurgeRelayWebAPI;
assert.ok(api, 'web api should install a global testable API');
const stateHelpers = context.SurgeRelayWebState;
assert.ok(stateHelpers, 'web state should install a global testable API');
const editorHelpers = context.SurgeRelayWebEditor;
assert.ok(editorHelpers, 'web editor should install a global testable API');
const feedbackHelpers = context.SurgeRelayWebFeedback;
assert.ok(feedbackHelpers, 'web feedback should install a global testable API');
const previewHelpers = context.SurgeRelayWebPreview;
assert.ok(previewHelpers, 'web preview should install a global testable API');
assert.equal(options.scriptHubDefaults.removeCommentedRewrites, true);
assert.ok(
  options.advancedGroups.some(group => group.id === 'script-conversion'),
  'advanced option groups should include script conversion controls'
);
assert.doesNotMatch(
  appSource,
  /function (moduleSubtitle|moduleStatusTitle|failureSummary|folderTitle|publishedRelativePathForDraft|outputPathNotice|isValidHTTPURL|isNativeSurgeSource|validateModuleEditorFields|moduleEditorPayload|activityPresentation|normalizedOutputFileName|suggestedNameFromSource|normalizeFolder|isFileSource|sgmoduleName|existingSgmoduleName|baseName|existingFileBaseName)\(/,
  'app.js should call web-logic helpers directly instead of re-declaring wrappers'
);
assert.doesNotMatch(
  appSource,
  /function (setAdvancedExpanded|animateAdvancedResize|animateOptionGroup|collectScriptHubOptions|populateScriptHubOptions|hasAdvancedValues|populateOutputFolders|updateIconURLPreview|scheduleNameLookup)\(/,
  'app.js should use web-editor helpers for editor UI details'
);
assert.doesNotMatch(
  appSource,
  /form\.(name|category|iconURL|outputFolder|outputFileName|sourceURL|sourceFormat|storageLocation)\.value/,
  'app.js should let web-editor populate and collect module form fields'
);
assert.doesNotMatch(
  appSource,
  /function (openDialog|closeDialog|askConfirmation|resolveConfirmation|resetHorizontalScroll|copyText|showCopySuccess|showToast)\(/,
  'app.js should use web-feedback helpers for feedback and dialog details'
);
assert.doesNotMatch(
  appSource,
  /function (loadPreview|savePreview|restorePreview)\(/,
  'app.js should use web-preview helpers for preview state and actions'
);
assert.doesNotMatch(
  appSource,
  /history\.(pushState|replaceState)\(\{\s*surgeRelay/,
  'app.js should use web-state helpers to construct history entries'
);
assert.doesNotMatch(
  appSource,
  /detail-value monospaced">\$\{escapeHTML\((combined\.subscriptionURL|module\.publishedURL)\)\}/,
  'app.js should use web-markup for copyable URL sections'
);

assert.equal(
  logic.publishedRelativePathForDraft({
    name: 'YouTube Ads',
    sourceURL: 'https://example.com/plugin.lpx',
    storageLocation: 'gitHub',
    outputFolder: ' Ads / Video ',
    outputFileName: ''
  }),
  'Ads/Video/YouTube-Ads.sgmodule'
);

assert.equal(
  logic.publishedRelativePathForDraft({
    name: 'YouTube Ads',
    sourceURL: 'https://example.com/source.sgmodule',
    storageLocation: 'local',
    outputFolder: 'Ads',
    outputFileName: 'YouTube Ads.sgmodule'
  }),
  'Ads/YouTube Ads.sgmodule'
);

assert.equal(
  logic.outputPathNotice('Surge-Relay.sgmodule', true, { combinedFileName: 'Surge Relay' }).warning,
  true
);

assert.match(
  logic.outputPathNotice('Folder/Demo.sgmodule', true, {
    modules: [{ id: 'one', name: 'Demo', publishedRelativePath: 'Folder/Demo.sgmodule' }]
  }).message,
  /Demo/
);

assert.equal(
  logic.outputPathNotice('Folder/Demo.sgmodule', true, {
    modules: [{ id: 'one', name: 'Demo', publishedRelativePath: 'Folder/Demo.sgmodule' }],
    editingID: 'one'
  }),
  null
);

assert.equal(
  logic.outputPathNotice('Folder/Demo.sgmodule', false).message,
  '未开启独立发布时，不会写出这个独立模块文件。'
);

assert.equal(logic.isValidHTTPURL('https://example.com/icon.png'), true);
assert.equal(logic.isValidHTTPURL('http://example.com/icon.png'), true);
assert.equal(logic.isValidHTTPURL('ftp://example.com/icon.png'), false);
assert.equal(logic.isValidHTTPURL('/icon.png'), false);
assert.equal(logic.validateModuleEditorFields({ iconURL: 'https://example.com/icon.png' }), null);
assert.deepEqual(
  JSON.parse(JSON.stringify(logic.validateModuleEditorFields({ iconURL: 'file:///tmp/icon.png' }))),
  {
    field: 'iconURL',
    message: '图标 URL 仅支持完整的 HTTP 或 HTTPS 地址。'
  }
);

assert.equal(logic.isNativeSurgeSource('surge', 'https://example.com/plugin.lpx'), true);
assert.equal(logic.isNativeSurgeSource('automatic', 'https://example.com/demo.sgmodule'), true);
assert.equal(logic.isNativeSurgeSource('automatic', 'https://example.com/surge/modules/demo.conf'), true);
assert.equal(logic.isNativeSurgeSource('automatic', 'https://example.com/plugin.lpx'), false);

assert.deepEqual(
  JSON.parse(JSON.stringify(logic.moduleEditorPayload({
    name: '  Demo  ',
    sourceURL: ' https://example.com/demo.sgmodule ',
    sourceFormat: 'surge',
    storageLocation: 'local',
    category: '  Ads  ',
    iconURL: ' https://example.com/icon.png ',
    outputFolder: 'Folder',
    outputFileName: ' Demo Module.sgmodule ',
    isEnabled: true,
    publishesStandalone: false,
    scriptHubOptions: { jqEnabled: true }
  }, {
    combinedEnabled: true,
    existingModule: { isEnabled: false }
  }))),
  {
    name: 'Demo',
    sourceURL: 'https://example.com/demo.sgmodule',
    sourceFormat: 'surge',
    storageLocation: 'local',
    category: 'Ads',
    iconURL: 'https://example.com/icon.png',
    outputFolder: 'Folder',
    outputFileName: 'Demo Module.sgmodule',
    isEnabled: true,
    publishesStandalone: false,
    scriptHubOptions: { jqEnabled: true }
  }
);
assert.equal(
  logic.moduleEditorPayload({ isEnabled: true }, {
    combinedEnabled: false,
    existingModule: { isEnabled: false }
  }).isEnabled,
  false,
  'saving while combined module is disabled should preserve the existing include state'
);
assert.equal(
  logic.moduleEditorPayload({ isEnabled: false }, {
    combinedEnabled: false,
    existingModule: { isEnabled: true }
  }).isEnabled,
  true,
  'editing while combined module is disabled should not silently remove a previous include state'
);

const signatureBase = {
  id: 'module-1',
  name: 'Demo',
  sourceURL: 'https://example.com/demo.sgmodule',
  effectiveOriginalSourceURL: 'https://example.com/demo.sgmodule',
  sourceFormatTitle: 'Surge 模块',
  outputFolder: 'Folder',
  publishedRelativePath: 'Folder/Demo.sgmodule',
  storageLocation: 'gitHub',
  storageLocationTitle: 'GitHub 模块',
  sourceOriginTitle: '远程 Surge 模块',
  relationshipSummary: 'GitHub 模块 · 远程 Surge 模块',
  localStorageRelativePath: '',
  iconURL: '',
  customIconURL: '',
  isEnabled: false,
  publishesStandalone: true,
  state: 'current',
  stateTitle: '已是最新',
  lastError: '',
  lastUpdatedAt: '2026-07-04T12:00:00Z',
  sourceCheckedAt: '2026-07-04T12:00:00Z',
  contentHash: 'abc',
  sourceContentHash: 'def',
  sourceETag: 'etag',
  sourceLastModified: 'date',
  conversionEngineRevision: 'rev'
};
assert.notEqual(
  logic.moduleListSignature(signatureBase),
  logic.moduleListSignature({ ...signatureBase, relationshipSummary: '本地模块 · 远程 Surge 模块' })
);
assert.notEqual(
  logic.moduleListSignature(signatureBase),
  logic.moduleListSignature({ ...signatureBase, lastError: '原始链接返回 404' })
);
assert.notEqual(
  logic.moduleListSignature({ ...signatureBase, name: 'A\u001fB', sourceURL: 'C' }),
  logic.moduleListSignature({ ...signatureBase, name: 'A', sourceURL: 'B\u001fC' }),
  'module list signatures should not collide when field values contain legacy separators'
);
assert.notEqual(
  logic.sidebarListSignature({ combined: { isEnabled: false }, modules: [signatureBase] }),
  logic.sidebarListSignature({ combined: { isEnabled: true }, modules: [signatureBase] })
);
assert.notEqual(
  logic.sidebarListSignature({ combined: { isEnabled: false }, modules: [signatureBase] }),
  logic.sidebarListSignature({
    combined: { isEnabled: false },
    modules: [{ ...signatureBase, relationshipSummary: '本地模块 · 远程 Surge 模块' }]
  })
);
assert.equal(
  logic.metadataRowPresenceChanged(signatureBase, { ...signatureBase, lastUpdatedAt: '2026-07-05T12:00:00Z' }),
  false
);
assert.equal(
  logic.metadataRowPresenceChanged(signatureBase, { ...signatureBase, sourceETag: '' }),
  true
);
assert.equal(
  logic.metadataRowPresenceChanged(signatureBase, { ...signatureBase, localStorageRelativePath: 'Folder/Demo.sgmodule' }),
  true
);

assert.equal(
  logic.moduleMatchesSearch({
    ...signatureBase,
    outputFileName: 'Demo File.sgmodule',
    category: 'Ads',
    lastError: '原始链接返回 404',
    publishesStandalone: false
  }, ' demo file '),
  true
);
assert.equal(
  logic.moduleMatchesSearch({
    ...signatureBase,
    outputFileName: 'Demo File.sgmodule',
    category: 'Ads',
    lastError: '原始链接返回 404',
    publishesStandalone: false
  }, '原始链接返回 404'),
  true
);
assert.equal(
  logic.moduleMatchesSearch({
    ...signatureBase,
    outputFileName: 'Demo File.sgmodule',
    category: 'Ads',
    publishesStandalone: false
  }, '不发布独立模块'),
  true
);
assert.equal(
  logic.moduleMatchesSearch(signatureBase, '不存在的模块字段'),
  false
);

const sidebarModules = [
  { ...signatureBase, id: 'failed-1', name: 'Block HTTPDNS', state: 'failed', lastError: '原始链接返回 404' },
  { ...signatureBase, id: 'current-1', name: 'Clean Module', state: 'current', lastError: '' },
  { ...signatureBase, id: 'failed-2', name: 'Proxy Rewrite', state: 'failed', lastError: 'DNS 查询失败' }
];
const activeFailureFilter = logic.sidebarFailureFilterState(sidebarModules, true);
assert.equal(activeFailureFilter.failedCount, 2);
assert.equal(activeFailureFilter.failuresOnly, true);
assert.equal(activeFailureFilter.isVisible, true);
assert.equal(activeFailureFilter.label, '失败 2');
const hiddenFailureFilter = logic.sidebarFailureFilterState([{ ...signatureBase, state: 'current' }], true);
assert.equal(hiddenFailureFilter.failedCount, 0);
assert.equal(hiddenFailureFilter.failuresOnly, false);
assert.equal(hiddenFailureFilter.isVisible, false);
assert.equal(hiddenFailureFilter.label, '失败 0');
assert.deepEqual(
  Array.from(logic.sidebarModules(sidebarModules, { query: 'rewrite', failuresOnly: true }).map(module => module.id)),
  ['failed-2']
);
assert.deepEqual(
  Array.from(logic.sidebarModules(sidebarModules, { query: 'clean', failuresOnly: true }).map(module => module.id)),
  []
);
assert.equal(logic.sidebarEmptyText({ query: 'missing', failuresOnly: false }), '没有搜索结果');
assert.equal(logic.sidebarEmptyText({ query: '', failuresOnly: true }), '没有更新失败的模块');
assert.equal(logic.sidebarEmptyText({ query: '', failuresOnly: false }), '还没有模块');

assert.deepEqual(
  JSON.parse(JSON.stringify(logic.activityPresentation({
    kind: 'idle',
    status: '',
    title: '',
    canStartUpdate: true,
    canCancel: false,
    isWorking: false,
    progress: null
  }))),
  {
    statusText: '准备就绪',
    refreshDisabled: false,
    refreshTitle: '更新全部',
    refreshAriaLabel: '更新全部',
    showCancel: false,
    canCancel: false,
    cancelLabel: '取消',
    progressPercent: null,
    progressVisible: false,
    progressWidth: '0%'
  }
);
assert.deepEqual(
  JSON.parse(JSON.stringify(logic.activityPresentation({
    kind: 'idle',
    status: '等待本地模块根目录',
    canStartUpdate: false,
    updateBlockedReason: '请先配置本地模块根目录',
    automaticPublishRunsAt: '2026-07-04T12:00:00Z'
  }, {
    formatAutomaticPublish: value => `formatted ${value}`
  }))),
  {
    statusText: '等待本地模块根目录 · 自动发布 formatted 2026-07-04T12:00:00Z',
    refreshDisabled: true,
    refreshTitle: '请先配置本地模块根目录',
    refreshAriaLabel: '无法更新：请先配置本地模块根目录',
    showCancel: false,
    canCancel: false,
    cancelLabel: '取消',
    progressPercent: null,
    progressVisible: false,
    progressWidth: '0%'
  }
);
assert.deepEqual(
  JSON.parse(JSON.stringify(logic.activityPresentation({
    kind: 'updating',
    title: '更新',
    status: '正在转换模块',
    canStartUpdate: false,
    canCancel: true,
    cancellationRequested: false,
    isWorking: true,
    progress: 1.4
  }))),
  {
    statusText: '更新 · 正在转换模块',
    refreshDisabled: true,
    refreshTitle: '当前无法开始更新',
    refreshAriaLabel: '无法更新：当前无法开始更新',
    showCancel: true,
    canCancel: true,
    cancelLabel: '取消',
    progressPercent: 100,
    progressVisible: true,
    progressWidth: '100%'
  }
);
assert.equal(
  logic.activityPresentation({
    kind: 'updating',
    canCancel: true,
    cancellationRequested: true,
    isWorking: true,
    progress: 0.42
  }).cancelLabel,
  '正在取消'
);

assert.equal(
  logic.moduleSubtitle({
    relationshipSummary: 'GitHub 模块 · 远程 Surge 模块',
    category: 'Ads',
    outputFolder: 'Folder',
    publishesStandalone: false,
    state: 'current'
  }),
  'GitHub 模块 · 远程 Surge 模块 · Ads · Folder · 不发布独立模块'
);

assert.equal(
  logic.moduleSubtitle({
    sourceFormatTitle: 'Surge 模块',
    publishesStandalone: true,
    state: 'failed',
    lastError: '原始链接返回 404\n请检查路径'
  }),
  '更新失败：原始链接返回 404'
);

assert.equal(format.escapeHTML('<tag attr="1">Tom & Jerry</tag>'), '&lt;tag attr=&quot;1&quot;&gt;Tom &amp; Jerry&lt;/tag&gt;');
assert.equal(format.formatDate('not-a-date', 'fallback'), 'fallback');
assert.match(format.highlightCode('[General]\nkey = https://example.com/1'), /code-section/);
assert.match(format.highlightCode('[General]\nkey = https://example.com/1'), /code-url/);
assert.match(markup.emptyStateMarkup('magnifyingglass', '没有 <模块>'), /没有 &lt;模块&gt;/);
const selectedModuleRow = markup.moduleRowMarkup({
  ...signatureBase,
  id: 'module<1',
  name: 'Demo <Module>',
  iconURL: 'https://example.com/icon.png?a=1&b=2',
  customIconURL: '',
  isEnabled: false,
  publishesStandalone: false,
  state: 'failed',
  stateTitle: '更新失败',
  lastError: '原始链接返回 404'
}, {
  selectedID: 'module<1',
  combinedEnabled: true
});
assert.match(selectedModuleRow, /module-row selected disabled/);
assert.match(selectedModuleRow, /data-id="module&lt;1"/);
assert.match(selectedModuleRow, /data-module-toggle="module&lt;1"/);
assert.match(selectedModuleRow, /Demo &lt;Module&gt;/);
assert.match(selectedModuleRow, /https:\/\/example.com\/icon.png\?a=1&amp;b=2/);
assert.match(selectedModuleRow, /更新失败：原始链接返回 404/);
assert.match(selectedModuleRow, /不发布独立模块/);
const standaloneModuleRow = markup.moduleRowMarkup({
  ...signatureBase,
  id: 'module-2',
  iconURL: '',
  isEnabled: true,
  state: 'current',
  lastError: ''
}, {
  selectedID: null,
  combinedEnabled: false
});
assert.match(standaloneModuleRow, /module-icon placeholder/);
assert.doesNotMatch(standaloneModuleRow, /data-module-toggle/);
assert.match(markup.detailRow('link', '原始地址', '<unsafe>'), /&lt;unsafe&gt;/);
assert.match(markup.detailRow('link', '原始地址', '<a>ok</a>', true, 'https://example.com?a=1&b=2'), /data-value="https:\/\/example.com\?a=1&amp;b=2"/);
assert.equal(markup.copyableValueSection('GitHub', ''), '');
assert.match(markup.copyableValueSection('GitHub <地址>', 'https://example.com?a=1&b=2', '复制 <URL>'), /GitHub &lt;地址&gt;/);
assert.match(markup.copyableValueSection('GitHub <地址>', 'https://example.com?a=1&b=2', '复制 <URL>'), /data-value="https:\/\/example.com\?a=1&amp;b=2"/);
assert.match(markup.copyableValueSection('GitHub <地址>', 'https://example.com?a=1&b=2', '复制 <URL>'), /复制 &lt;URL&gt;/);
assert.match(markup.previewShell('Demo <Module>', true), /Demo &lt;Module&gt;/);
assert.match(markup.previewShell('Demo', true), /textarea/);
assert.match(markup.argumentMarkup({ key: 'enabled<', value: 'true', defaultValue: 'false' }), /enabled&lt;/);
assert.equal(markup.argumentsSectionMarkup({ arguments: [] }), '');
assert.match(markup.argumentsSectionMarkup({
  arguments: [
    { key: 'enabled<', value: 'true', defaultValue: 'false' },
    { key: 'host', value: 'example.com', defaultValue: 'example.org' }
  ],
  help: '输入 <host> 后立即生效'
}), /输入 &lt;host&gt; 后立即生效/);
assert.doesNotMatch(markup.argumentsSectionMarkup({
  arguments: [{ key: 'host', value: 'example.com', defaultValue: 'example.org' }]
}), /reset-arguments" disabled/);
assert.match(markup.argumentsSectionMarkup({
  arguments: [{ key: 'host', value: 'example.org', defaultValue: 'example.org' }]
}), /reset-arguments" disabled/);
assert.match(markup.advancedGroupMarkup({
  id: 'unsafe"><',
  title: '高级 <选项>',
  description: '说明 & 帮助',
  fields: [{ key: 'host', type: 'text', label: '主机', prompt: 'example.com', help: '仅测试' }]
}), /data-option-group="unsafe&quot;&gt;&lt;"/);
assert.match(markup.advancedOptionsMarkup([{
  id: 'group<1',
  title: '高级 <选项>',
  description: '',
  fields: [{ key: 'host', type: 'text', label: '主机', prompt: 'example.com' }]
}]), /advanced-intro/);
const folderOptionsMarkup = markup.outputFolderOptionsMarkup(['Beta', 'A&B', 'Quote"Folder'], 'Selected<Folder>');
assert.match(folderOptionsMarkup, /^<option value="">根目录<\/option>/);
assert.match(folderOptionsMarkup, /value="A&amp;B">A&amp;B<\/option>/);
assert.match(folderOptionsMarkup, /value="Quote&quot;Folder">Quote&quot;Folder<\/option>/);
assert.match(folderOptionsMarkup, /value="Selected&lt;Folder&gt;">Selected&lt;Folder&gt;<\/option>/);
assert.match(markup.latestPublishSection({
  commitSHA: 'abcdef123456',
  commitURL: 'https://example.com/commit/abcdef',
  date: '2026-07-04T12:00:00Z',
  publishedFiles: ['A&B.sgmodule'],
  deletedFiles: ['Old.sgmodule']
}), /A&amp;B\.sgmodule/);
assert.match(markup.detailToolbar('preview', true), /data-action="edit"/);
assert.match(markup.detailToolbar('preview', true), /tab-preview" class="selected"/);
assert.match(markup.combinedDetailMarkup({
  isEnabled: true,
  name: 'Surge Relay 汇总',
  fileName: 'Surge Relay.sgmodule',
  enabledCount: 2,
  sourceCount: 3,
  subscriptionURL: 'https://example.com/combined.sgmodule',
  lastUpdatedAt: '2026-07-04T12:00:00Z'
}, {
  selectedTab: 'info',
  latestGitHubPublish: {
    commitSHA: 'abcdef123456',
    commitURL: 'https://example.com/commit/abcdef',
    date: '2026-07-04T12:00:00Z',
    publishedFiles: ['Combined.sgmodule'],
    deletedFiles: []
  }
}), /总模块订阅地址/);
assert.match(
  markup.combinedDetailMarkup({ isEnabled: false }, { selectedTab: 'info' }),
  /总模块功能未开启/
);
assert.match(
  markup.combinedDetailMarkup({
    isEnabled: true,
    fileName: 'Surge Relay.sgmodule'
  }, { selectedTab: 'preview' }),
  /code-view/
);
const failedModuleDetail = markup.moduleDetailMarkup({
  ...signatureBase,
  name: 'Unsafe <Module>',
  sourceURL: 'https://example.com/fallback.sgmodule',
  effectiveOriginalSourceURL: 'https://example.com/source.sgmodule?a=1&b=2',
  category: 'Ads',
  outputFolder: '',
  outputFileName: 'Unsafe.sgmodule',
  publishedRelativePath: 'Folder/Unsafe.sgmodule',
  publishedURL: 'https://example.com/published.sgmodule',
  localStorageRelativePath: 'Local/Unsafe.sgmodule',
  customIconURL: 'https://example.com/icon.png?x=1&y=2',
  state: 'failed',
  stateTitle: '更新失败',
  lastError: '原始链接返回 404\n请检查仓库路径',
  advancedSummary: 'jq: .payload',
  hasOverrideConflict: true,
  storageLocationIcon: 'folder',
  sourceOriginIcon: 'link'
}, {
  selectedTab: 'info',
  combined: {
    isEnabled: true,
    subscriptionURL: 'https://example.com/combined.sgmodule'
  }
});
assert.ok(
  failedModuleDetail.indexOf('最近一次更新失败') >= 0 &&
    failedModuleDetail.indexOf('最近一次更新失败') < failedModuleDetail.indexOf('管理关系'),
  'module detail markup should keep failure reason before relationship details'
);
assert.match(failedModuleDetail, /原始地址/);
assert.match(failedModuleDetail, /https:\/\/example.com\/source.sgmodule\?a=1&amp;b=2/);
assert.match(failedModuleDetail, /https:\/\/example.com\/icon.png\?x=1&amp;y=2/);
assert.match(failedModuleDetail, /复制错误/);
assert.match(failedModuleDetail, /本地编辑冲突/);
assert.match(
  markup.moduleDetailMarkup(signatureBase, { selectedTab: 'preview', combined: { isEnabled: false } }),
  /code-editor/
);

const tokenHistory = { state: { route: 'modules' }, replacedURL: '', replaceState(state, title, url) { this.state = state; this.replacedURL = String(url); } };
const tokenClient = api.createAPIClient({
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => ({ ok: true }) }),
  Headers,
  location: { href: 'https://relay.example.test/?token=secret-token&module=one' },
  history: tokenHistory
});
assert.equal(tokenClient.initializeAccessToken(), 'secret-token');
assert.equal(tokenClient.accessToken, 'secret-token');
assert.doesNotMatch(tokenHistory.replacedURL, /token=/);
assert.match(tokenHistory.replacedURL, /module=one/);

let capturedRequest = null;
const requestClient = api.createAPIClient({
  fetch: async (path, options) => {
    capturedRequest = { path, options };
    return {
      ok: true,
      status: 200,
      headers: { get: name => name.toLowerCase() === 'content-type' ? 'application/json' : '' },
      json: async () => ({ saved: true })
    };
  },
  Headers,
  accessToken: 'token-1'
});
assert.deepEqual(await requestClient.request('/api/demo', {
  method: 'POST',
  json: { enabled: true },
  includeAccessToken: true
}), { saved: true });
assert.equal(capturedRequest.path, '/api/demo');
assert.equal(capturedRequest.options.method, 'POST');
assert.equal(capturedRequest.options.credentials, 'same-origin');
assert.equal(capturedRequest.options.headers.get('Content-Type'), 'application/json');
assert.equal(capturedRequest.options.headers.get('Authorization'), 'Bearer token-1');
assert.equal(capturedRequest.options.body, '{"enabled":true}');

const retryPaths = [];
const retryClient = api.createAPIClient({
  fetch: async path => {
    retryPaths.push(path);
    if (retryPaths.length === 1) {
      return { ok: false, status: 401, headers: { get: () => '' }, json: async () => ({ message: 'unauthorized' }) };
    }
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => ({ recovered: true }) };
  },
  Headers,
  prompt: () => 'fresh-token'
});
assert.deepEqual(await retryClient.request('/api/state'), { recovered: true });
assert.deepEqual(retryPaths, ['/api/state', '/api/session', '/api/state']);
assert.equal(retryClient.accessToken, 'fresh-token');

const navigationState = {
  combined: { isEnabled: true },
  modules: [{ id: 'module-1' }, { id: 'module-2' }]
};
assert.equal(stateHelpers.combinedEnabled(navigationState), true);
assert.equal(stateHelpers.fallbackSelection(navigationState, false), 'combined');
assert.equal(stateHelpers.fallbackSelection(navigationState, true), null);
const requestedSelection = stateHelpers.resolveInitialSelection(navigationState, {
  requestedModuleID: 'module-2',
  isMobile: false
});
assert.equal(requestedSelection.selectedID, 'module-2');
assert.equal(requestedSelection.hasSelection, true);
const mobileSelection = stateHelpers.resolveInitialSelection(navigationState, {
  requestedModuleID: 'missing',
  isMobile: true
});
assert.equal(mobileSelection.selectedID, null);
assert.equal(mobileSelection.hasSelection, false);
const normalizedSelection = stateHelpers.normalizeSelection({
  combined: { isEnabled: false },
  modules: [{ id: 'module-1' }]
}, 'combined', false);
assert.equal(normalizedSelection.selectedID, 'module-1');
assert.equal(normalizedSelection.changed, true);
assert.equal(
  stateHelpers.moduleIDFromLocation({ href: 'https://relay.example.test/?module=module-1&token=redacted' }),
  'module-1'
);
assert.doesNotMatch(
  String(stateHelpers.urlWithoutModule({ href: 'https://relay.example.test/?module=module-1&token=redacted' })),
  /module=/
);
assert.match(
  String(stateHelpers.urlWithModule({ href: 'https://relay.example.test/?token=redacted' }, 'module-2')),
  /module=module-2/
);
const initialHistoryWithModule = stateHelpers.initialHistoryTransition({
  href: 'https://relay.example.test/?module=module-1&token=redacted'
}, null);
assert.equal(initialHistoryWithModule.replace.state.view, 'list');
assert.equal(initialHistoryWithModule.replace.state.module, null);
assert.doesNotMatch(String(initialHistoryWithModule.replace.url), /module=/);
assert.equal(initialHistoryWithModule.push.state.view, 'detail');
assert.equal(initialHistoryWithModule.push.state.module, 'module-1');
assert.equal(initialHistoryWithModule.push.state.cameFromList, true);
assert.match(String(initialHistoryWithModule.push.url), /module=module-1/);
assert.equal(
  stateHelpers.initialHistoryTransition({ href: 'https://relay.example.test/' }, { surgeRelay: true }),
  null
);
const initialHistoryWithoutModule = stateHelpers.initialHistoryTransition({
  href: 'https://relay.example.test/?token=redacted'
}, null);
assert.equal(initialHistoryWithoutModule.replace.state.view, 'list');
assert.equal(initialHistoryWithoutModule.push, null);
assert.match(String(initialHistoryWithoutModule.replace.url), /token=redacted/);
const detailHistoryEntry = stateHelpers.detailHistoryEntry({ href: 'https://relay.example.test/' }, 'module-2', true);
assert.equal(detailHistoryEntry.state.view, 'detail');
assert.equal(detailHistoryEntry.state.cameFromList, true);
assert.match(String(detailHistoryEntry.url), /module=module-2/);
const listHistoryEntry = stateHelpers.listHistoryEntry({ href: 'https://relay.example.test/?module=module-2' });
assert.equal(listHistoryEntry.state.view, 'list');
assert.doesNotMatch(String(listHistoryEntry.url), /module=/);
assert.equal(stateHelpers.mobileBackAction({ surgeRelay: true, cameFromList: true }), 'back');
assert.equal(stateHelpers.mobileBackAction({ surgeRelay: true, cameFromList: false }), 'show-list');
assert.deepEqual(
  JSON.parse(JSON.stringify(stateHelpers.historyNavigationTarget({ href: 'https://relay.example.test/' }, { view: 'list' }, true, 'module-1'))),
  { action: 'show-list', moduleID: null }
);
assert.deepEqual(
  JSON.parse(JSON.stringify(stateHelpers.historyNavigationTarget({ href: 'https://relay.example.test/?module=module-2' }, { view: 'detail' }, true, 'module-1'))),
  { action: 'select', moduleID: 'module-2' }
);
assert.deepEqual(
  JSON.parse(JSON.stringify(stateHelpers.historyNavigationTarget({ href: 'https://relay.example.test/' }, { view: 'list' }, false, 'module-1'))),
  { action: 'select', moduleID: 'module-1' }
);

let eventSource = null;
const appliedStates = [];
const reloads = [];
const reconnectTimers = [];
let sessionRefreshCount = 0;
class TestEventSource {
  constructor(url) {
    this.url = url;
    this.listeners = new Map();
    eventSource = this;
  }

  addEventListener(type, handler) {
    this.listeners.set(type, handler);
  }

  close() {
    this.closed = true;
  }
}
const eventController = stateHelpers.createStateEventController({
  EventSource: TestEventSource,
  document: { hidden: false },
  setInterval: () => 0,
  setTimeout: (handler, delay) => {
    reconnectTimers.push({ handler, delay });
    return reconnectTimers.length;
  },
  applyState: (...args) => appliedStates.push(args),
  loadState: async (...args) => reloads.push(args),
  establishSession: async () => { sessionRefreshCount += 1; },
  reconnectDelay: 25
});
eventController.start();
assert.equal(eventSource.url, '/api/events');
eventSource.listeners.get('state')({ data: '{"modules":[]}' });
assert.equal(appliedStates[0][0].modules.length, 0);
assert.equal(appliedStates[0][1], false);
assert.equal(appliedStates[0][2], false);
eventSource.onerror();
await new Promise(resolve => setImmediate(resolve));
await new Promise(resolve => setImmediate(resolve));
assert.equal(eventSource.closed, true);
assert.equal(sessionRefreshCount, 1);
assert.deepEqual(reloads[0], [false, false]);
assert.equal(reconnectTimers[0].delay, 25);

function makeClassList() {
  const values = new Set();
  return {
    add(name) { values.add(name); },
    remove(name) { values.delete(name); },
    contains(name) { return values.has(name); },
    toggle(name, force) {
      if (force) values.add(name); else values.delete(name);
    }
  };
}

const editorFormElements = {
  name: { value: 'Demo Module' },
  sourceURL: { value: 'https://example.com/source.sgmodule' },
  sourceFormat: { value: 'automatic' },
  storageLocation: { value: 'local' },
  outputFolder: { value: 'Folder' },
  outputFileName: { value: '' },
  publishesStandalone: { checked: true },
  iconURL: { value: '' }
};
Object.entries(options.scriptHubDefaults).forEach(([key, value]) => {
  editorFormElements[`option_${key}`] = typeof value === 'boolean'
    ? { checked: value }
    : { value };
});
const advancedGroupElements = Object.fromEntries(
  options.advancedGroups.map(group => [`[data-option-group="${group.id}"]`, { open: false }])
);
const editorUI = {
  moduleForm: { elements: editorFormElements },
  advancedOptions: {
    innerHTML: '',
    hidden: false,
    querySelector: selector => advancedGroupElements[selector] || null
  },
  advancedMaster: {
    attributes: {},
    setAttribute(name, value) { this.attributes[name] = value; }
  },
  advancedContent: {
    attributes: {},
    classList: makeClassList(),
    style: {},
    offsetHeight: 0,
    setAttribute(name, value) { this.attributes[name] = value; }
  },
  moduleDialog: { open: false },
  nativeNote: { hidden: true },
  outputPathPreview: { textContent: '' },
  outputPathNote: {
    textContent: '',
    hidden: true,
    classList: makeClassList()
  },
  iconURLPreview: {
    dataset: { fallbackIconUrl: '' },
    classList: makeClassList(),
    innerHTML: '',
    title: '',
    append(node) { this.appended = node; }
  }
};
const createdElements = [];
const editorTimers = [];
const clearedEditorTimers = [];
const editorController = editorHelpers.createModuleEditorController({
  ui: editorUI,
  logic,
  markup,
  scriptHubDefaults: options.scriptHubDefaults,
  advancedGroups: options.advancedGroups,
  document: {
    createElement(tagName) {
      const element = {
        tagName,
        addEventListener(type, handler) { this.listener = { type, handler }; }
      };
      createdElements.push(element);
      return element;
    }
  },
  window: { matchMedia: () => ({ matches: false }) },
  mobileLayout: { matches: false },
  setTimeout: (handler, delay) => {
    const timer = { handler, delay };
    editorTimers.push(timer);
    return editorTimers.length;
  },
  clearTimeout: timer => clearedEditorTimers.push(timer)
});
editorController.installAdvancedOptions();
assert.match(editorUI.advancedOptions.innerHTML, /advanced-intro/);
editorController.setAdvancedExpanded(true);
assert.equal(editorUI.advancedMaster.attributes['aria-expanded'], 'true');
assert.equal(editorUI.advancedContent.attributes['aria-hidden'], 'false');
assert.equal(editorUI.advancedContent.classList.contains('expanded'), true);
assert.equal(editorController.updateNativeModuleState(), true);
assert.equal(editorUI.nativeNote.hidden, false);
assert.equal(editorUI.advancedOptions.hidden, true);
editorFormElements.sourceURL.value = 'https://example.com/plugin.lpx';
assert.equal(editorController.updateNativeModuleState(), false);
assert.equal(editorUI.nativeNote.hidden, true);
assert.equal(editorUI.advancedOptions.hidden, false);
editorController.populateScriptHubOptions({
  includeKeywords: 'ads+trackers',
  convertAllScripts: true
});
assert.equal(editorFormElements.option_includeKeywords.value, 'ads+trackers');
assert.equal(editorFormElements.option_convertAllScripts.checked, true);
assert.equal(advancedGroupElements['[data-option-group="rewrites"]'].open, true);
assert.equal(advancedGroupElements['[data-option-group="script-conversion"]'].open, true);
assert.equal(editorController.collectScriptHubOptions().includeKeywords, 'ads+trackers');
assert.equal(editorController.collectScriptHubOptions().convertAllScripts, true);
assert.equal(editorController.hasAdvancedValues({ includeKeywords: 'ads+trackers' }), true);
assert.equal(editorController.hasAdvancedValues({}), false);
editorController.populateOutputFolders('Folder', ['Beta', 'Folder']);
assert.equal(editorFormElements.outputFolder.value, 'Folder');
assert.match(editorFormElements.outputFolder.innerHTML, /value="Folder">Folder/);
editorFormElements.sourceURL.value = 'https://example.com/source.sgmodule';
const outputPreview = editorController.updateOutputPathPreview({
  state: {
    combined: { fileName: 'Surge Relay' },
    modules: [{ id: 'other', name: 'Other Module', publishedRelativePath: 'Folder/Demo Module.sgmodule' }]
  },
  editingID: null
});
assert.equal(outputPreview.path, 'Folder/Demo Module.sgmodule');
assert.equal(outputPreview.notice.warning, true);
assert.match(editorUI.outputPathNote.textContent, /Other Module/);
assert.equal(editorUI.outputPathNote.hidden, false);
assert.equal(editorUI.outputPathNote.classList.contains('warning'), true);
editorFormElements.iconURL.value = 'file:///tmp/icon.png';
editorController.updateIconURLPreview();
assert.equal(editorUI.iconURLPreview.classList.contains('invalid'), true);
assert.match(editorUI.iconURLPreview.innerHTML, /shippingbox/);
editorFormElements.iconURL.value = 'https://example.com/icon.png';
editorController.updateIconURLPreview();
assert.equal(createdElements.at(-1).tagName, 'img');
assert.equal(createdElements.at(-1).src, 'https://example.com/icon.png');
let nameLookupUpdates = 0;
const nameLookupRequests = [];
editorController.resetNameLookup('', false);
editorFormElements.name.value = '';
editorFormElements.sourceURL.value = 'https://example.com/named.plugin';
assert.equal(editorController.scheduleNameLookup({
  api: async (path, options) => {
    nameLookupRequests.push({ path, options });
    return { name: 'Auto Name' };
  },
  updateOutputPathPreview: () => { nameLookupUpdates += 1; },
  delay: 7
}), true);
assert.equal(editorTimers.at(-1).delay, 7);
await editorTimers.at(-1).handler();
assert.equal(nameLookupRequests[0].path, '/api/source/name');
assert.equal(nameLookupRequests[0].options.json.url, 'https://example.com/named.plugin');
assert.equal(editorFormElements.name.value, 'Auto Name');
assert.equal(editorController.autoFilledName, 'Auto Name');
assert.equal(nameLookupUpdates, 1);
assert.equal(editorController.handleNameInput('Manual Name'), true);
assert.equal(editorController.manualNameEdited, true);
assert.equal(editorController.scheduleNameLookup({
  api: async () => { throw new Error('manual names should not be overwritten'); },
  updateOutputPathPreview: () => {},
  delay: 1
}), false);
assert.equal(editorController.handleNameInput(''), false);
editorController.resetNameLookup('', false);
editorFormElements.name.value = '';
editorFormElements.sourceURL.value = 'https://example.com/stale.plugin';
let staleUpdated = false;
assert.equal(editorController.scheduleNameLookup({
  api: async () => ({ name: 'Stale Name' }),
  updateOutputPathPreview: () => { staleUpdated = true; },
  delay: 9
}), true);
editorFormElements.sourceURL.value = 'https://example.com/new.plugin';
await editorTimers.at(-1).handler();
assert.equal(editorFormElements.name.value, '');
assert.equal(staleUpdated, false);
assert.equal(editorController.resetNameLookup('Existing Name', true).manualNameEdited, true);
assert.ok(clearedEditorTimers.length >= 1);

const feedbackTimers = [];
const clearedTimers = [];
const toastElement = {
  textContent: '',
  classList: makeClassList()
};
const confirmDialog = {
  open: false,
  classList: makeClassList(),
  showModal() { this.open = true; },
  close() { this.open = false; }
};
const feedbackDocument = {
  documentElement: { scrollLeft: 12 },
  body: {
    scrollLeft: 34,
    append(node) { this.appended = node; }
  },
  createElement(tagName) {
    return {
      tagName,
      value: '',
      selected: false,
      removed: false,
      select() { this.selected = true; },
      remove() { this.removed = true; }
    };
  },
  execCommand(command) {
    this.lastCommand = command;
    return true;
  }
};
const feedbackWindow = {
  scrollY: 56,
  scrollTo(x, y) { this.scrolledTo = [x, y]; }
};
const copiedTexts = [];
const feedbackController = feedbackHelpers.createFeedbackController({
  ui: {
    confirmDialog,
    confirmTitle: { textContent: '' },
    confirmMessage: { textContent: '' },
    confirmAccept: { textContent: '' },
    toast: toastElement
  },
  document: feedbackDocument,
  window: feedbackWindow,
  navigator: { clipboard: { writeText: async text => copiedTexts.push(text) } },
  setTimeout: (handler, delay) => {
    const timer = { handler, delay };
    feedbackTimers.push(timer);
    if (delay === 1) handler();
    return feedbackTimers.length;
  },
  clearTimeout: timer => clearedTimers.push(timer),
  closeDelay: 1,
  copySuccessDelay: 2,
  toastDelay: 3
});
feedbackController.openDialog(confirmDialog);
assert.equal(confirmDialog.open, true);
assert.equal(confirmDialog.classList.contains('is-closing'), false);
const confirmPromise = feedbackController.askConfirmation('删除模块？', '确认删除 Demo？', '删除');
assert.equal(confirmDialog.open, true);
await feedbackController.resolveConfirmation(true);
assert.equal(await confirmPromise, true);
assert.equal(confirmDialog.open, false);
feedbackController.resetHorizontalScroll();
assert.equal(feedbackDocument.documentElement.scrollLeft, 0);
assert.equal(feedbackDocument.body.scrollLeft, 0);
assert.deepEqual(feedbackWindow.scrolledTo, [0, 56]);
const copyButton = {
  dataset: {},
  innerHTML: '<span>复制</span>',
  isConnected: true,
  classList: makeClassList()
};
assert.equal(await feedbackController.copyText('https://example.com/module.sgmodule', copyButton), true);
assert.deepEqual(copiedTexts, ['https://example.com/module.sgmodule']);
assert.match(copyButton.innerHTML, /拷贝成功/);
assert.equal(copyButton.classList.contains('copy-success'), true);
feedbackTimers.find(timer => timer.delay === 2).handler();
assert.equal(copyButton.innerHTML, '<span>复制</span>');
assert.equal(copyButton.classList.contains('copy-success'), false);
feedbackController.showToast('保存成功');
assert.equal(toastElement.textContent, '保存成功');
assert.equal(toastElement.classList.contains('visible'), true);
feedbackTimers.findLast(timer => timer.delay === 3).handler();
assert.equal(toastElement.classList.contains('visible'), false);
const failedToast = { textContent: '', classList: makeClassList() };
const failedCopyController = feedbackHelpers.createFeedbackController({
  ui: { toast: failedToast },
  document: feedbackDocument,
  navigator: { clipboard: { writeText: async () => { throw new Error('denied'); } } },
  setTimeout: () => 1,
  clearTimeout: () => {}
});
assert.equal(await failedCopyController.copyText('secret'), false);
assert.equal(failedToast.textContent, '拷贝失败');
assert.equal(failedToast.classList.contains('error'), true);

const previewAPIRequests = [];
const previewToasts = [];
const previewElements = {
  '#code-editor': {
    value: '',
    listeners: {},
    addEventListener(type, handler) { this.listeners[type] = handler; }
  },
  '#code-view': { innerHTML: '' },
  '[data-action="save-preview"]': { disabled: true }
};
const previewController = previewHelpers.createPreviewController({
  api: async (path, options = {}) => {
    previewAPIRequests.push({ path, options });
    if (path === '/api/modules/module-1/preview' && options.method === 'PUT') return { message: '预览已保存' };
    if (path === '/api/modules/module-1/preview' && options.method === 'DELETE') return 'restored content';
    if (path === '/api/modules/module-1/preview') return 'editable content';
    if (path === '/api/combined/preview') return '[General]\nkey = value';
    throw new Error('missing route');
  },
  document: {
    querySelector: selector => previewElements[selector] || null
  },
  highlightCode: text => `<pre>${text}</pre>`,
  askConfirmation: async () => true,
  showToast: (message, isError = false) => previewToasts.push({ message, isError })
});
await previewController.loadPreview('/api/combined/preview', false);
assert.equal(previewElements['#code-view'].innerHTML, '<pre>[General]\nkey = value</pre>');
assert.equal(previewController.text, '[General]\nkey = value');
await previewController.loadPreview('/api/modules/module-1/preview', true);
assert.equal(previewElements['#code-editor'].value, 'editable content');
assert.equal(previewController.savedText, 'editable content');
previewElements['#code-editor'].value = 'edited content';
previewElements['#code-editor'].listeners.input();
assert.equal(previewController.text, 'edited content');
assert.equal(previewElements['[data-action="save-preview"]'].disabled, false);
await previewController.savePreview({ id: 'module-1' });
assert.equal(previewAPIRequests.at(-1).options.method, 'PUT');
assert.equal(previewAPIRequests.at(-1).options.body, 'edited content');
assert.equal(previewController.savedText, 'edited content');
assert.equal(previewElements['[data-action="save-preview"]'].disabled, true);
assert.deepEqual(previewToasts.at(-1), { message: '预览已保存', isError: false });
await previewController.restorePreview({ id: 'module-1', name: 'Demo Module' });
assert.equal(previewAPIRequests.at(-1).options.method, 'DELETE');
assert.equal(previewElements['#code-editor'].value, 'restored content');
assert.equal(previewController.text, 'restored content');
assert.equal(previewController.savedText, 'restored content');
assert.deepEqual(previewToasts.at(-1), { message: '已恢复转换结果', isError: false });
const refusedRestoreRequests = [];
const refusedPreviewController = previewHelpers.createPreviewController({
  api: async (...args) => refusedRestoreRequests.push(args),
  document: { querySelector: () => null },
  askConfirmation: async () => false
});
await refusedPreviewController.restorePreview({ id: 'module-1', name: 'Demo Module' });
assert.equal(refusedRestoreRequests.length, 0);

const indexHTML = readFileSync(new URL('../SurgeRelay/WebResources/index.html', import.meta.url), 'utf8');
const logicScriptIndex = indexHTML.indexOf('/web-logic.js');
const optionsScriptIndex = indexHTML.indexOf('/web-options.js');
const formatScriptIndex = indexHTML.indexOf('/web-format.js');
const markupScriptIndex = indexHTML.indexOf('/web-markup.js');
const apiScriptIndex = indexHTML.indexOf('/web-api.js');
const stateScriptIndex = indexHTML.indexOf('/web-state.js');
const editorScriptIndex = indexHTML.indexOf('/web-editor.js');
const feedbackScriptIndex = indexHTML.indexOf('/web-feedback.js');
const previewScriptIndex = indexHTML.indexOf('/web-preview.js');
const appScriptIndex = indexHTML.indexOf('/app.js');
assert.ok(logicScriptIndex >= 0, 'index should load web-logic.js');
assert.ok(optionsScriptIndex > logicScriptIndex, 'web-options.js must load after web-logic.js');
assert.ok(formatScriptIndex > optionsScriptIndex, 'web-format.js must load after web-options.js');
assert.ok(markupScriptIndex > formatScriptIndex, 'web-markup.js must load after web-format.js');
assert.ok(apiScriptIndex > markupScriptIndex, 'web-api.js must load after web-markup.js');
assert.ok(stateScriptIndex > apiScriptIndex, 'web-state.js must load after web-api.js');
assert.ok(editorScriptIndex > stateScriptIndex, 'web-editor.js must load after web-state.js');
assert.ok(feedbackScriptIndex > editorScriptIndex, 'web-feedback.js must load after web-editor.js');
assert.ok(previewScriptIndex > feedbackScriptIndex, 'web-preview.js must load after web-feedback.js');
assert.ok(appScriptIndex > previewScriptIndex, 'web-preview.js must load before app.js');
assert.match(indexHTML, /name="storageLocation"/);
assert.match(indexHTML, /name="outputFolder"/);
assert.match(indexHTML, /id="output-path-preview"/);

console.log('Web resource behavior tests passed');
