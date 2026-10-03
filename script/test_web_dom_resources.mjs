import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const root = new URL('../', import.meta.url);
const indexHTML = readFileSync(new URL('SurgeRelay/WebResources/index.html', root), 'utf8');
const logicSource = readFileSync(new URL('SurgeRelay/WebResources/web-logic.js', root), 'utf8');
const optionsSource = readFileSync(new URL('SurgeRelay/WebResources/web-options.js', root), 'utf8');
const formatSource = readFileSync(new URL('SurgeRelay/WebResources/web-format.js', root), 'utf8');
const markupSource = readFileSync(new URL('SurgeRelay/WebResources/web-markup.js', root), 'utf8');
const sidebarSource = readFileSync(new URL('SurgeRelay/WebResources/web-sidebar.js', root), 'utf8');
const activitySource = readFileSync(new URL('SurgeRelay/WebResources/web-activity.js', root), 'utf8');
const apiSource = readFileSync(new URL('SurgeRelay/WebResources/web-api.js', root), 'utf8');
const stateSource = readFileSync(new URL('SurgeRelay/WebResources/web-state.js', root), 'utf8');
const editorSource = readFileSync(new URL('SurgeRelay/WebResources/web-editor.js', root), 'utf8');
const feedbackSource = readFileSync(new URL('SurgeRelay/WebResources/web-feedback.js', root), 'utf8');
const previewSource = readFileSync(new URL('SurgeRelay/WebResources/web-preview.js', root), 'utf8');
const detailSource = readFileSync(new URL('SurgeRelay/WebResources/web-detail.js', root), 'utf8');
const appSource = readFileSync(new URL('SurgeRelay/WebResources/app.js', root), 'utf8');

const requiredIDs = [
  'module-list', 'summary-row', 'summary-subtitle', 'detail-content', 'search-input', 'clear-search', 'search-status',
  'filter-row', 'failure-filter', 'add-button', 'refresh-button', 'mobile-back', 'mobile-title', 'workspace-name', 'mobile-workspace-name', 'activity-status',
  'activity-stages', 'activity-percent', 'progress-track', 'progress-fill', 'activity-cancel', 'latest-update',
  'module-dialog', 'module-dialog-message', 'module-form', 'icon-url-preview',
  'output-path-preview', 'output-path-note', 'dialog-title', 'save-module-button',
  'advanced-master', 'advanced-master-content', 'advanced-options', 'native-module-note',
  'confirm-dialog', 'confirm-title', 'confirm-message', 'confirm-cancel', 'confirm-accept',
  'operation-dialog', 'operation-title', 'operation-content', 'operation-close', 'custom-refresh-row', 'toast'
];

const requiredFormNames = [
  'name', 'category', 'iconURL', 'storageLocation', 'outputFolder', 'outputFileName',
  'isEnabled', 'publishesStandalone', 'sourceURL', 'sourceFormat', 'refreshIntervalMinutes', 'customRefreshIntervalMinutes'
];

for (const id of requiredIDs) {
  assert.match(indexHTML, new RegExp(`id="${id}"`), `index.html should contain #${id}`);
}
for (const name of requiredFormNames) {
  assert.match(indexHTML, new RegExp(`name="${name}"`), `index.html should contain [name="${name}"]`);
}

class FakeClassList {
  constructor() {
    this.values = new Set();
  }

  add(...names) {
    names.forEach(name => this.values.add(name));
  }

  remove(...names) {
    names.forEach(name => this.values.delete(name));
  }

  toggle(name, force) {
    const shouldAdd = force === undefined ? !this.values.has(name) : Boolean(force);
    if (shouldAdd) this.values.add(name);
    else this.values.delete(name);
    return shouldAdd;
  }

  contains(name) {
    return this.values.has(name);
  }
}

class FakeElement {
  constructor(document, { id = '', tagName = 'div', name = '' } = {}) {
    this.ownerDocument = document;
    this.id = id;
    this.tagName = tagName.toUpperCase();
    this.name = name;
    this.dataset = {};
    this.style = {};
    this.classList = new FakeClassList();
    this.listeners = new Map();
    this.children = [];
    this.attributes = new Map();
    this.hidden = false;
    this.disabled = false;
    this.checked = false;
    this.value = '';
    this.open = false;
    this.scrollTop = 0;
    this.scrollLeft = 0;
    this._innerHTML = '';
    this._textContent = '';
    this.lastSpan = null;
  }

  set innerHTML(value) {
    this._innerHTML = String(value ?? '');
    this._textContent = stripTags(this._innerHTML);
  }

  get innerHTML() {
    return this._innerHTML;
  }

  set textContent(value) {
    this._textContent = String(value ?? '');
    this._innerHTML = escapeHTML(this._textContent);
  }

  get textContent() {
    return this._textContent;
  }

  addEventListener(type, handler) {
    const handlers = this.listeners.get(type) || [];
    handlers.push(handler);
    this.listeners.set(type, handlers);
  }

  dispatch(type, event = {}) {
    const payload = { target: this, currentTarget: this, ...event };
    for (const handler of this.listeners.get(type) || []) {
      handler(payload);
    }
  }

  append(...children) {
    this.children.push(...children);
  }

  focus() {}
  select() {}
  remove() {}

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
    if (name === 'aria-expanded') this.ariaExpanded = String(value);
    if (name === 'aria-hidden') this.ariaHidden = String(value);
  }

  getAttribute(name) {
    return this.attributes.get(name) ?? null;
  }

  querySelector(selector) {
    if (selector.startsWith('#')) return this.ownerDocument.querySelector(selector);
    if (selector === 'span:last-child') {
      if (!this.lastSpan) this.lastSpan = new FakeElement(this.ownerDocument, { tagName: 'span' });
      return this.lastSpan;
    }
    if (selector === '.form-content') return this.ownerDocument.formContent;
    if (selector.startsWith('[data-option-group=')) return null;
    return null;
  }

  querySelectorAll() {
    return [];
  }

  closest(selector) {
    if (selector === '.switch-row') return this.ownerDocument.switchRows.get(this.name) || null;
    return null;
  }

  showModal() {
    this.open = true;
  }

  close() {
    this.open = false;
  }

  getBoundingClientRect() {
    return { height: 320 };
  }

  animate() {
    return { finished: Promise.resolve() };
  }
}

class FakeForm extends FakeElement {
  constructor(document) {
    super(document, { id: 'module-form', tagName: 'form' });
    this.elements = {};
  }
}

class FakeDocument {
  listeners = new Map();

  addEventListener(type, callback) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(callback);
    this.listeners.set(type, listeners);
  }

  removeEventListener(type, callback) {
    this.listeners.set(type, (this.listeners.get(type) || []).filter(listener => listener !== callback));
  }

  constructor() {
    this.elementsByID = new Map();
    this.switchRows = new Map();
    this.body = this.register(new FakeElement(this, { tagName: 'body' }));
    this.documentElement = new FakeElement(this, { tagName: 'html' });
    this.formContent = new FakeElement(this, { tagName: 'div' });
    this.closeButtons = [
      new FakeElement(this, { tagName: 'button' }),
      new FakeElement(this, { tagName: 'button' })
    ];
    this.seed();
  }

  seed() {
    for (const id of requiredIDs) {
      if (id === 'module-form') continue;
      const element = new FakeElement(this, {
        id,
        tagName: id.endsWith('dialog') ? 'dialog' : elementTagName(id)
      });
      this.register(element);
    }
    const form = this.register(new FakeForm(this));
    for (const name of requiredFormNames) {
      const field = new FakeElement(this, {
        tagName: selectFieldNames.has(name) ? 'select' : 'input',
        name
      });
      field.type = checkboxFieldNames.has(name) ? 'checkbox' : 'text';
      field.checked = name === 'publishesStandalone';
      if (name === 'storageLocation') field.value = 'gitHub';
      if (name === 'sourceFormat') field.value = 'automatic';
      form.elements[name] = field;
      if (checkboxFieldNames.has(name)) {
        this.switchRows.set(name, new FakeElement(this, { tagName: 'label' }));
      }
    }
  }

  register(element) {
    if (element.id) this.elementsByID.set(element.id, element);
    return element;
  }

  querySelector(selector) {
    if (selector.startsWith('#')) return this.elementsByID.get(selector.slice(1)) || null;
    return null;
  }

  querySelectorAll(selector) {
    if (selector === '.close-module-dialog') return this.closeButtons;
    return [];
  }

  createElement(tagName) {
    return new FakeElement(this, { tagName });
  }

  execCommand() {
    return true;
  }
}

const selectFieldNames = new Set(['storageLocation', 'outputFolder', 'sourceFormat', 'refreshIntervalMinutes']);
const checkboxFieldNames = new Set(['isEnabled', 'publishesStandalone']);

function elementTagName(id) {
  if (id.endsWith('button') || id.startsWith('confirm-') || id === 'advanced-master') return 'button';
  if (id.includes('dialog')) return 'dialog';
  if (id.includes('input')) return 'input';
  if (id.includes('progress')) return 'span';
  return 'div';
}

function stripTags(value) {
  return String(value).replace(/<[^>]*>/g, '');
}

function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>'"]/g, character => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    "'": '&#39;',
    '"': '&quot;'
  })[character]);
}

function fakeState() {
  return {
    combined: {
      isEnabled: false,
      name: 'Surge Relay',
      fileName: 'Surge Relay',
      enabledCount: 0,
      sourceCount: 2,
      lastUpdatedAt: null,
      subscriptionURL: null
    },
    activity: {
      kind: 'idle',
      title: '',
      status: '准备就绪',
      blocksUpdates: false,
      canCancel: false,
      cancellationRequested: false,
      isWorking: false,
      progress: null,
      canStartUpdate: true,
      updateBlockedReason: null,
      automaticPublishRunsAt: null,
      latestGitHubPublish: null
    },
    moduleEditor: {
      defaultStorageLocation: 'gitHub',
      localOutputFolders: ['', 'Local'],
      githubOutputFolders: ['', 'Ads/Video'],
      publishToLocal: true,
      publishToGitHub: true
    },
    modules: [
      {
        id: 'module-1',
        name: 'Block HTTPDNS',
        sourceURL: 'https://raw.githubusercontent.com/example/repo/main/block.conf',
        initialSourceURL: 'https://raw.githubusercontent.com/example/repo/main/block.conf',
        updateSourceURL: 'https://raw.githubusercontent.com/example/repo/main/block.conf',
        sourceFormat: 'quantumultX',
        sourceFormatTitle: 'Quantumult X 重写',
        initialSourceTitle: '订阅 Quantumult X',
        initialSourceIcon: 'link',
        storageLocation: 'gitHub',
        storageLocationTitle: 'GitHub 模块',
        storageLocationDetail: '储存在 GitHub 模块目录',
        storageLocationIcon: 'cloud',
        relationshipSummary: 'GitHub 模块 · 订阅 Quantumult X',
        localStorageRelativePath: null,
        outputFileName: 'Block-HTTPDNS.sgmodule',
        publishedRelativePath: 'Ads/Video/Block-HTTPDNS.sgmodule',
        category: '#2 警条模块',
        outputFolder: 'Ads/Video',
        iconURL: '',
        customIconURL: '',
        isEnabled: false,
        publishesStandalone: true,
        state: 'failed',
        stateTitle: '更新失败',
        lastError: '原始链接返回 404：https://raw.githubusercontent.com/example/repo/main/block.conf',
        lastUpdatedAt: null,
        sourceCheckedAt: null,
        contentHash: null,
        sourceContentHash: null,
        sourceETag: null,
        sourceLastModified: null,
        conversionEngineRevision: null,
        advancedSummary: '',
        scriptHubOptions: {}
      },
      {
        id: 'module-2',
        name: 'Clean Module',
        sourceURL: 'https://example.com/clean.sgmodule',
        initialSourceURL: null,
        updateSourceURL: 'https://example.com/clean.sgmodule',
        sourceFormat: 'surge',
        sourceFormatTitle: 'Surge 模块',
        initialSourceTitle: '自写模块',
        initialSourceIcon: 'pencil.and.outline',
        storageLocation: 'gitHub',
        storageLocationTitle: 'GitHub 模块',
        storageLocationDetail: '储存在 GitHub 模块目录',
        storageLocationIcon: 'cloud',
        relationshipSummary: 'GitHub 模块 · 自写模块',
        localStorageRelativePath: null,
        outputFileName: 'Clean-Module.sgmodule',
        publishedRelativePath: 'Clean-Module.sgmodule',
        category: '',
        outputFolder: '',
        iconURL: '',
        customIconURL: '',
        isEnabled: false,
        publishesStandalone: true,
        state: 'current',
        stateTitle: '已是最新',
        lastError: '',
        lastUpdatedAt: null,
        sourceCheckedAt: null,
        contentHash: null,
        sourceContentHash: null,
        sourceETag: null,
        sourceLastModified: null,
        conversionEngineRevision: null,
        advancedSummary: '',
        scriptHubOptions: {}
      }
    ]
  };
}

function fakeJSONResponse(value) {
  return {
    ok: true,
    status: 200,
    headers: { get: name => name.toLowerCase() === 'content-type' ? 'application/json' : '' },
    json: async () => value,
    text: async () => JSON.stringify(value)
  };
}

class FakeEventSource {
  constructor(url) {
    this.url = url;
    this.listeners = new Map();
  }

  addEventListener(type, handler) {
    this.listeners.set(type, handler);
  }

  close() {
    this.closed = true;
  }
}

const document = new FakeDocument();
const capturedRequests = [];
const copiedHistory = [];
let finishWorkspaceRequest;
const context = vm.createContext({
  console,
  document,
  location: { href: 'https://relay.example.test/' },
  history: {
    state: null,
    replaceState(state) { this.state = state; },
    pushState(state) { this.state = state; },
    back() {}
  },
  navigator: { clipboard: { writeText: async text => copiedHistory.push(text) } },
  URL,
  Headers,
  Intl,
  setTimeout: () => 0,
  clearTimeout: () => {},
  setInterval: () => 0,
  clearInterval: () => {},
  fetch: async (path, options = {}) => {
    capturedRequests.push({ path: String(path), options });
    if (path === '/api/slow-write') return new Promise(resolve => { finishWorkspaceRequest = () => resolve(fakeJSONResponse({ message: 'old result' })); });
    if (path === '/api/state') return fakeJSONResponse(fakeState());
    if (String(path).endsWith('/arguments')) return fakeJSONResponse({ arguments: [], help: null });
    if (path === '/api/session') return fakeJSONResponse({ message: 'ok' });
    return fakeJSONResponse({ message: 'ok' });
  },
  EventSource: FakeEventSource
});
context.window = context;
context.window.matchMedia = () => ({
  matches: false,
  addEventListener() {},
  removeEventListener() {}
});
context.window.addEventListener = () => {};
context.window.scrollTo = () => {};
context.window.prompt = () => '';
context.globalThis = context;

vm.runInContext(logicSource, context, { filename: 'web-logic.js' });
vm.runInContext(optionsSource, context, { filename: 'web-options.js' });
vm.runInContext(formatSource, context, { filename: 'web-format.js' });
vm.runInContext(markupSource, context, { filename: 'web-markup.js' });
vm.runInContext(sidebarSource, context, { filename: 'web-sidebar.js' });
vm.runInContext(activitySource, context, { filename: 'web-activity.js' });
vm.runInContext(apiSource, context, { filename: 'web-api.js' });
vm.runInContext(stateSource, context, { filename: 'web-state.js' });
vm.runInContext(editorSource, context, { filename: 'web-editor.js' });
vm.runInContext(feedbackSource, context, { filename: 'web-feedback.js' });
vm.runInContext(previewSource, context, { filename: 'web-preview.js' });
vm.runInContext(detailSource, context, { filename: 'web-detail.js' });
vm.runInContext(appSource, context, { filename: 'app.js' });

await flushAsync();
await flushAsync();

const list = document.querySelector('#module-list');
const detail = document.querySelector('#detail-content');
const refresh = document.querySelector('#refresh-button');
const search = document.querySelector('#search-input');
const filterRow = document.querySelector('#filter-row');
const failureFilter = document.querySelector('#failure-filter');
assert.match(list.innerHTML, /Block HTTPDNS/, 'app.js should render module rows from /api/state');
assert.match(list.innerHTML, /Clean Module/, 'app.js should render non-failed module rows before filtering');
assert.match(list.innerHTML, /更新失败：原始链接返回 404/, 'sidebar should show failure summary');
assert.equal(filterRow.hidden, false, 'failure filter row should appear when failed modules exist');
assert.equal(failureFilter.hidden, false, 'failure filter should appear when failed modules exist');
assert.equal(failureFilter.getAttribute('aria-pressed'), 'false', 'failure filter should start inactive');
failureFilter.dispatch('click');
assert.equal(failureFilter.getAttribute('aria-pressed'), 'true', 'failure filter should toggle on');
assert.match(list.innerHTML, /Block HTTPDNS/, 'failure filter should keep failed modules visible');
assert.doesNotMatch(list.innerHTML, /Clean Module/, 'failure filter should hide non-failed modules');
assert.match(detail.innerHTML, /模块工作台/, 'desktop opens the workspace overview');
vm.runInContext("selectItem('module-1', false)", context);
assert.match(detail.innerHTML, /管理关系/, 'selecting a module opens its detail');
assert.ok(
  detail.innerHTML.indexOf('最近一次更新失败') >= 0 &&
    detail.innerHTML.indexOf('最近一次更新失败') < detail.innerHTML.indexOf('管理关系'),
  'module detail should expose failure reason before management details'
);
assert.match(detail.innerHTML, /复制错误/, 'module detail should provide a copy action for failure reasons');
assert.match(detail.innerHTML, /订阅原始地址/, 'module detail should expose subscribed original source address');
assert.equal(refresh.disabled, false, 'refresh button should stay enabled when update admission allows it');

failureFilter.dispatch('click');
assert.equal(failureFilter.getAttribute('aria-pressed'), 'false', 'failure filter should turn off before plain search');
search.value = 'Clean';
search.dispatch('input');
assert.match(list.innerHTML, /Clean Module/, 'search should keep matching modules visible');
assert.doesNotMatch(list.innerHTML, /Block HTTPDNS/, 'search should hide non-matching modules');
search.value = '';
search.dispatch('input');
assert.match(list.innerHTML, /Block HTTPDNS/, 'clearing search should restore failed modules');
assert.match(list.innerHTML, /Clean Module/, 'clearing search should restore current modules');

document.querySelector('#add-button').dispatch('click');
const form = document.querySelector('#module-form').elements;
assert.equal(form.storageLocation.value, 'gitHub');
assert.equal(document.querySelector('#workspace-name').textContent, '默认工作区');
assert.equal(document.querySelector('#mobile-workspace-name').textContent, '默认工作区');
assert.match(form.outputFolder.innerHTML, /Ads\/Video/);
assert.doesNotMatch(form.outputFolder.innerHTML, /Local/);
form.name.value = 'YouTube Ads';
form.name.dispatch('input');
form.sourceURL.value = 'https://example.com/plugin.lpx';
form.sourceURL.dispatch('input');
form.outputFolder.value = 'Ads/Video';
form.outputFolder.dispatch('change');
assert.equal(
  document.querySelector('#output-path-preview').textContent,
  'Ads/Video/YouTube-Ads.sgmodule',
  'GitHub output preview should sanitize generated names'
);

form.storageLocation.value = 'local';
form.outputFileName.value = 'YouTube Ads.sgmodule';
form.storageLocation.dispatch('change');
assert.match(form.outputFolder.innerHTML, /Local/);
assert.doesNotMatch(form.outputFolder.innerHTML, /Ads\/Video/);
form.outputFolder.value = 'Local';
form.outputFolder.dispatch('change');
form.outputFileName.dispatch('input');
assert.equal(
  document.querySelector('#output-path-preview').textContent,
  'Local/YouTube Ads.sgmodule',
  'local output preview should preserve existing file names'
);

form.publishesStandalone.checked = false;
form.publishesStandalone.dispatch('change');
const note = document.querySelector('#output-path-note');
assert.equal(note.hidden, false);
assert.match(note.textContent, /不会写出这个独立模块文件/);

form.storageLocation.value = 'both';
form.storageLocation.dispatch('change');
assert.match(form.outputFolder.innerHTML, /Local/);
assert.match(form.outputFolder.innerHTML, /Ads\/Video/);
assert.equal(document.querySelector('#output-path-preview').textContent, 'Local/YouTube Ads.sgmodule');
form.refreshIntervalMinutes.value = 'custom';
form.refreshIntervalMinutes.dispatch('change');
assert.equal(document.querySelector('#custom-refresh-row').hidden, false);
form.customRefreshIntervalMinutes.value = '37';
form.category.value = 'Ads';
form.sourceFormat.value = 'quantumultX';
form.iconURL.value = 'https://example.com/icon.png';
form.publishesStandalone.checked = true;
document.querySelector('#module-form').dispatch('submit', { preventDefault() {} });
await flushAsync();
await flushAsync();
const saveRequest = capturedRequests.find(request => request.path === '/api/modules' && request.options.method === 'POST');
assert.ok(saveRequest, 'submitting the add-module form should post to /api/modules');
assert.deepEqual(JSON.parse(saveRequest.options.body), {
  refreshIntervalMinutes: 37,
  name: 'YouTube Ads',
  sourceURL: 'https://example.com/plugin.lpx',
  sourceFormat: 'quantumultX',
  storageLocation: 'local',
  storageTargets: ['local', 'gitHub'],
  category: 'Ads',
  iconURL: 'https://example.com/icon.png',
  outputFolder: 'Local',
  outputFileName: 'YouTube Ads.sgmodule',
  isEnabled: false,
  publishesStandalone: true,
  scriptHubOptions: JSON.parse(JSON.stringify(context.SurgeRelayWebOptions.scriptHubDefaults))
});

const updateCount = () => capturedRequests.filter(request => request.path === '/api/modules/module-1/update').length;
vm.runInContext("selectedID = 'module-1'; state.modules[0].serverRetryAfter = new Date(Date.now() + 60000).toISOString()", context);
const beforeCooldownUpdate = updateCount();
await vm.runInContext("handleDetailClick({target:{closest:()=>({dataset:{action:'update-module'}})}})", context);
assert.equal(updateCount(), beforeCooldownUpdate, 'manual updates do not send requests during server cooldown');
vm.runInContext("state.modules[0].serverRetryAfter = null; state.modules[0].nextRetryAt = new Date(Date.now() + 60000).toISOString()", context);
await vm.runInContext("handleDetailClick({target:{closest:()=>({dataset:{action:'update-module'}})}})", context);
assert.equal(updateCount(), beforeCooldownUpdate + 1, 'ordinary backoff does not prevent a manual update');
context.workspaceState = { ...fakeState(), workspace: { id: 'A', name: 'Workspace A', isLegacyDefault: false } };
await vm.runInContext('applyState(workspaceState, false, true)', context);
await vm.runInContext('api("/api/modules/module-1/update", {method:"POST"})', context);
assert.equal(capturedRequests.at(-1).options.headers.get('X-Relay-Workspace'), 'A');
await vm.runInContext('api("/api/source/name", {method:"POST", json:{url:"https://example.com/source"}})', context);
assert.equal(capturedRequests.at(-1).options.headers.get('X-Relay-Workspace'), null);
const oldRequest = vm.runInContext('api("/api/slow-write", {method:"POST"})', context);
assert.equal(capturedRequests.at(-1).options.headers.get('X-Relay-Workspace'), 'A', 'request header captures its originating workspace');
context.workspaceState = { ...fakeState(), workspace: { id: 'B', name: 'Workspace B', isLegacyDefault: false } };
vm.runInContext("selectedID='module-1'; editingID='module-1'; ui.search.value='old filter'; detailController.setTab('preview')", context);
await vm.runInContext('applyState(workspaceState, false, true)', context);
finishWorkspaceRequest();
await assert.rejects(oldRequest, /旧请求结果已忽略/);
assert.equal(vm.runInContext('selectedID', context), 'overview');
assert.match(document.querySelector('#module-list').innerHTML, /Block HTTPDNS/, 'same IDs in the new workspace rebuild real sidebar rows after cache reset');
assert.equal(vm.runInContext('editingID', context), null);
assert.equal(vm.runInContext('ui.search.value', context), '');
assert.equal(vm.runInContext('detailController.getTab()', context), 'info');
assert.match(document.querySelector('#toast').textContent, /已切换工作区：Workspace B/);
assert.equal(document.querySelector('#workspace-name').textContent, 'Workspace B');
assert.equal(document.querySelector('#mobile-workspace-name').title, 'Workspace B');
await vm.runInContext('api("/api/modules/module-1/update", {method:"POST"})', context);
assert.equal(capturedRequests.at(-1).options.headers.get('X-Relay-Workspace'), 'B');
context.workspaceState = fakeState();
await vm.runInContext('applyState(workspaceState, false, true)', context);
assert.equal(vm.runInContext('state.workspace.id', context), 'B', 'after identity is known, an unscoped state cannot revert to legacy data');
context.workspaceState = { ...fakeState(), workspace: { id: 'B', name: '很长的工作区 <name> '.repeat(20), isLegacyDefault: false } };
await vm.runInContext('applyState(workspaceState, false, true)', context);
assert.equal(document.querySelector('#workspace-name').textContent, context.workspaceState.workspace.name.trim());
assert.equal(document.querySelector('#workspace-name').title, context.workspaceState.workspace.name.trim());
assert.equal(document.querySelector('#mobile-workspace-name').textContent, context.workspaceState.workspace.name.trim());
vm.runInContext("state.workspace.recentHistory=[{moduleName:'Copied metrics',duration:2,stageMetrics:[{stage:'conversion',duration:3,attempts:1,failedAttempts:0,result:'completed',includesDownload:true,isPartial:true}]}]; selectedID='activity'; detailController.resetWorkspace()", context);
await vm.runInContext("handleDetailClick({target:{closest:()=>({dataset:{action:'copy-history',historyIndex:'0'},innerHTML:'复制记录',classList:{add(){},remove(){}}})}})", context);
assert.match(copiedHistory.at(-1), /转换\/下载（未拆分）/);
assert.match(copiedHistory.at(-1), /总耗时（记录）：2.00 秒/);
assert.match(copiedHistory.at(-1), /读取内容字节：未采集/);
const fullStateRequestsBeforeActivity = capturedRequests.filter(request => request.path === '/api/state').length;
const moduleRowsBeforeActivity = document.querySelector('#module-list').innerHTML;
const moduleReferenceBeforeActivity = vm.runInContext('state.modules', context);
await vm.runInContext("applyActivity({isWorking:true,kind:'updatingModules',progress:.25,completedCount:1,totalCount:4,activeStages:[{moduleID:'module-1',moduleName:'One',stage:'download'}]}, {source:'sse',workspaceID:'B'})", context);
assert.equal(document.querySelector('#activity-percent').textContent, '1/4');
assert.equal(document.querySelector('#activity-stages').textContent, '下载 1');
await vm.runInContext("applyActivity({isWorking:false,kind:'idle',progress:1}, {source:'sse',workspaceID:'B'})", context);
await flushAsync();
assert.equal(capturedRequests.filter(request => request.path === '/api/state').length, fullStateRequestsBeforeActivity, 'SSE completion does not request another full module snapshot');
assert.equal(document.querySelector('#module-list').innerHTML, moduleRowsBeforeActivity);
assert.equal(vm.runInContext('state.modules', context), moduleReferenceBeforeActivity, 'activity updates retain the existing module collection');
await vm.runInContext("applyActivity({isWorking:true,kind:'updatingModules',progress:.99}, {source:'sse',workspaceID:'A'})", context);
assert.equal(vm.runInContext('state.activity.kind', context), 'idle', 'old workspace activity cannot mutate the active UI');
context.versionedState = { ...fakeState(), workspace: { id: 'B', name: 'Workspace B', isLegacyDefault: false }, runtimeID: 'runtime-1', revision: 10, activity: { ...fakeState().activity, isWorking: true, progress: .1 } };
await vm.runInContext('applyState(versionedState, false, true)', context);
vm.runInContext("applyActivity({isWorking:true,kind:'updatingModules',progress:.3},{source:'sse',workspaceID:'B',runtimeID:'runtime-1',revision:30})", context);
context.versionedState = { ...context.versionedState, modules: context.versionedState.modules.map((module, index) => index ? module : { ...module, name: 'Core revision 20' }), revision: 20, activity: { ...context.versionedState.activity, progress: .2 } };
await vm.runInContext('applyState(versionedState, false, false)', context);
assert.equal(vm.runInContext('state.activity.progress', context), .3, 'late full-state activity cannot replace a newer SSE activity revision');
assert.equal(vm.runInContext('state.modules[0].name', context), 'Core revision 20', 'newer core data is accepted even when its revision precedes the latest activity');
assert.equal(await vm.runInContext('applyState(versionedState, false, false)', context), true, 'duplicate cached state on reconnect is accepted without reverting progress');
context.versionedState = { ...context.versionedState, runtimeID: 'runtime-2', revision: 1, activity: { ...context.versionedState.activity, progress: .01 } };
await vm.runInContext('applyState(versionedState, false, false)', context);
vm.runInContext("applyActivity({isWorking:true,progress:.99},{source:'sse',workspaceID:'B',runtimeID:'runtime-1',revision:99})", context);
assert.equal(vm.runInContext('state.activity.progress', context), .01);
context.versionedState = { ...context.versionedState, runtimeID: 'runtime-1', revision: 100 };
assert.equal(await vm.runInContext('applyState(versionedState, false, false)', context), false, 'retired runtime full-state callback is rejected');
assert.equal(vm.runInContext('state.runtimeID', context), 'runtime-2');
let finishActivityPoll;
context.activityPollResponse = new Promise(resolve => { finishActivityPoll = resolve; });
vm.runInContext(`
  var savedEventSource = EventSource; EventSource = undefined;
  var activityPollCallback;
  var revisionPoller = SurgeRelayWebState.createStateEventController({
    document: { hidden: false }, getWorkspaceID: () => currentWorkspace.id, getRuntimeID: () => currentRuntimeID,
    isWorking: () => true, loadState: async () => {}, applyState() {},
    fetchActivity: () => activityPollResponse, applyActivity: (value, metadata) => applyActivity(value, metadata),
    setInterval(callback, delay) { if (delay === 1000) activityPollCallback = callback; return delay; }, clearInterval() {}
  });
  EventSource = savedEventSource;
  revisionPoller.start(); activityPollCallback();
`, context);
await flushAsync();
context.versionedState = { ...context.versionedState, runtimeID: 'runtime-2', revision: 40, activity: { ...fakeState().activity, isWorking: true, progress: .4 } };
await vm.runInContext('applyState(versionedState, false, false)', context);
finishActivityPoll({ workspaceID: 'B', runtimeID: 'runtime-2', revision: 20, isWorking: true, progress: .2 });
await flushAsync();
assert.equal(vm.runInContext('state.activity.progress', context), .4, 'older same-runtime poll cannot overwrite a newer full HTTP snapshot');
context.activityPollResponse = new Promise(resolve => { finishActivityPoll = resolve; });
vm.runInContext('activityPollCallback()', context); await flushAsync();
vm.runInContext("applyActivity({isWorking:true,progress:.6},{source:'sse',workspaceID:'B',runtimeID:'runtime-2',revision:60})", context);
finishActivityPoll({ workspaceID: 'B', runtimeID: 'runtime-2', revision: 45, isWorking: true, progress: .45 });
await flushAsync();
assert.equal(vm.runInContext('state.activity.progress', context), .6, 'older same-runtime poll cannot overwrite newer SSE progress');
context.activityPollResponse = Promise.resolve({ workspaceID: 'B', runtimeID: 'runtime-2', revision: 61, isWorking: true, progress: .61 });
vm.runInContext('activityPollCallback()', context); await flushAsync();
assert.equal(vm.runInContext('state.activity.progress', context), .61);
context.activityPollResponse = Promise.resolve({ workspaceID: 'B', runtimeID: 'retired-runtime', revision: 99, isWorking: true, progress: .99 });
vm.runInContext('activityPollCallback()', context); await flushAsync();
assert.equal(vm.runInContext('state.activity.progress', context), .61, 'poll response metadata must match the captured runtime');
context.activityPollResponse = Promise.resolve({ isWorking: true, progress: .7 });
vm.runInContext('activityPollCallback()', context); await flushAsync();
assert.equal(vm.runInContext('state.activity.progress', context), .7, 'legacy flat activity without metadata still uses request-generation compatibility');
vm.runInContext('revisionPoller.close()', context);
console.log('Web DOM resource tests passed');

async function flushAsync() {
  await new Promise(resolve => setImmediate(resolve));
}
