import assert from 'node:assert/strict';
import { format, logic, markup } from './harness.mjs';

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
  initialSourceURL: null,
  updateSourceURL: 'https://example.com/demo.sgmodule',
  sourceFormatTitle: 'Surge 模块',
  outputFolder: 'Folder',
  publishedRelativePath: 'Folder/Demo.sgmodule',
  storageLocation: 'gitHub',
  storageLocationTitle: 'GitHub 模块',
  storageLocationDetail: '储存在 GitHub 模块目录',
  initialSourceTitle: '自写模块',
  relationshipSummary: 'GitHub 模块 · 自写模块',
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
  logic.moduleListSignature({ ...signatureBase, storageLocationDetail: '未开启独立发布；转换结果保存在本地缓存' })
);
assert.notEqual(
  logic.moduleListSignature(signatureBase),
  logic.moduleListSignature({ ...signatureBase, relationshipSummary: '本地模块 · 自写模块' })
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
    modules: [{ ...signatureBase, relationshipSummary: '本地模块 · 自写模块' }]
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
  initialSourceURL: 'https://example.com/source.sgmodule?a=1&b=2',
  updateSourceURL: 'https://example.com/source.sgmodule?a=1&b=2',
  initialSourceTitle: '订阅 Surge 模块',
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
  publishesStandalone: false,
  storageLocationDetail: '未开启独立发布；转换结果保存在本地缓存',
  storageLocationIcon: 'folder',
  initialSourceIcon: 'link'
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
assert.match(failedModuleDetail, /初始来源/);
assert.match(failedModuleDetail, /订阅原始地址/);
assert.match(failedModuleDetail, /独立模块存放/);
assert.match(failedModuleDetail, /未开启独立发布；转换结果保存在本地缓存/);
assert.match(failedModuleDetail, /https:\/\/example.com\/source.sgmodule\?a=1&amp;b=2/);
assert.match(failedModuleDetail, /https:\/\/example.com\/icon.png\?x=1&amp;y=2/);
assert.match(failedModuleDetail, /复制错误/);
assert.match(failedModuleDetail, /本地编辑冲突/);
assert.match(
  markup.moduleDetailMarkup(signatureBase, { selectedTab: 'preview', combined: { isEnabled: false } }),
  /code-editor/
);
