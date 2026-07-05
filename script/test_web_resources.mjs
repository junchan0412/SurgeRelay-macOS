import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const logicSource = readFileSync(new URL('../SurgeRelay/WebResources/web-logic.js', import.meta.url), 'utf8');
const optionsSource = readFileSync(new URL('../SurgeRelay/WebResources/web-options.js', import.meta.url), 'utf8');
const formatSource = readFileSync(new URL('../SurgeRelay/WebResources/web-format.js', import.meta.url), 'utf8');
const markupSource = readFileSync(new URL('../SurgeRelay/WebResources/web-markup.js', import.meta.url), 'utf8');
const apiSource = readFileSync(new URL('../SurgeRelay/WebResources/web-api.js', import.meta.url), 'utf8');
const stateSource = readFileSync(new URL('../SurgeRelay/WebResources/web-state.js', import.meta.url), 'utf8');
const appSource = readFileSync(new URL('../SurgeRelay/WebResources/app.js', import.meta.url), 'utf8');
const context = vm.createContext({ console, URL });
vm.runInContext(logicSource, context, { filename: 'web-logic.js' });
vm.runInContext(optionsSource, context, { filename: 'web-options.js' });
vm.runInContext(formatSource, context, { filename: 'web-format.js' });
vm.runInContext(markupSource, context, { filename: 'web-markup.js' });
vm.runInContext(apiSource, context, { filename: 'web-api.js' });
vm.runInContext(stateSource, context, { filename: 'web-state.js' });

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
assert.equal(options.scriptHubDefaults.removeCommentedRewrites, true);
assert.ok(
  options.advancedGroups.some(group => group.id === 'script-conversion'),
  'advanced option groups should include script conversion controls'
);
assert.doesNotMatch(
  appSource,
  /function (moduleSubtitle|moduleStatusTitle|failureSummary|folderTitle|publishedRelativePathForDraft|outputPathNotice|normalizedOutputFileName|suggestedNameFromSource|normalizeFolder|isFileSource|sgmoduleName|existingSgmoduleName|baseName|existingFileBaseName)\(/,
  'app.js should call web-logic helpers directly instead of re-declaring wrappers'
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
assert.match(markup.detailRow('link', '原始地址', '<unsafe>'), /&lt;unsafe&gt;/);
assert.match(markup.detailRow('link', '原始地址', '<a>ok</a>', true, 'https://example.com?a=1&b=2'), /data-value="https:\/\/example.com\?a=1&amp;b=2"/);
assert.equal(markup.copyableValueSection('GitHub', ''), '');
assert.match(markup.copyableValueSection('GitHub <地址>', 'https://example.com?a=1&b=2', '复制 <URL>'), /GitHub &lt;地址&gt;/);
assert.match(markup.copyableValueSection('GitHub <地址>', 'https://example.com?a=1&b=2', '复制 <URL>'), /data-value="https:\/\/example.com\?a=1&amp;b=2"/);
assert.match(markup.copyableValueSection('GitHub <地址>', 'https://example.com?a=1&b=2', '复制 <URL>'), /复制 &lt;URL&gt;/);
assert.match(markup.previewShell('Demo <Module>', true), /Demo &lt;Module&gt;/);
assert.match(markup.previewShell('Demo', true), /textarea/);
assert.match(markup.argumentMarkup({ key: 'enabled<', value: 'true', defaultValue: 'false' }), /enabled&lt;/);
assert.match(markup.advancedGroupMarkup({
  id: 'unsafe"><',
  title: '高级 <选项>',
  description: '说明 & 帮助',
  fields: [{ key: 'host', type: 'text', label: '主机', prompt: 'example.com', help: '仅测试' }]
}), /data-option-group="unsafe&quot;&gt;&lt;"/);
assert.match(markup.latestPublishSection({
  commitSHA: 'abcdef123456',
  commitURL: 'https://example.com/commit/abcdef',
  date: '2026-07-04T12:00:00Z',
  publishedFiles: ['A&B.sgmodule'],
  deletedFiles: ['Old.sgmodule']
}), /A&amp;B\.sgmodule/);

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

const indexHTML = readFileSync(new URL('../SurgeRelay/WebResources/index.html', import.meta.url), 'utf8');
const logicScriptIndex = indexHTML.indexOf('/web-logic.js');
const optionsScriptIndex = indexHTML.indexOf('/web-options.js');
const formatScriptIndex = indexHTML.indexOf('/web-format.js');
const markupScriptIndex = indexHTML.indexOf('/web-markup.js');
const apiScriptIndex = indexHTML.indexOf('/web-api.js');
const stateScriptIndex = indexHTML.indexOf('/web-state.js');
const appScriptIndex = indexHTML.indexOf('/app.js');
assert.ok(logicScriptIndex >= 0, 'index should load web-logic.js');
assert.ok(optionsScriptIndex > logicScriptIndex, 'web-options.js must load after web-logic.js');
assert.ok(formatScriptIndex > optionsScriptIndex, 'web-format.js must load after web-options.js');
assert.ok(markupScriptIndex > formatScriptIndex, 'web-markup.js must load after web-format.js');
assert.ok(apiScriptIndex > markupScriptIndex, 'web-api.js must load after web-markup.js');
assert.ok(stateScriptIndex > apiScriptIndex, 'web-state.js must load after web-api.js');
assert.ok(appScriptIndex > stateScriptIndex, 'web-state.js must load before app.js');
assert.match(indexHTML, /name="storageLocation"/);
assert.match(indexHTML, /name="outputFolder"/);
assert.match(indexHTML, /id="output-path-preview"/);

console.log('Web resource behavior tests passed');
