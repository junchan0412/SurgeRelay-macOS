import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const root = new URL('../', import.meta.url);
const indexHTML = readFileSync(new URL('SurgeRelay/WebResources/index.html', root), 'utf8');
const logicSource = readFileSync(new URL('SurgeRelay/WebResources/web-logic.js', root), 'utf8');
const appSource = readFileSync(new URL('SurgeRelay/WebResources/app.js', root), 'utf8');

const requiredIDs = [
  'module-list', 'summary-row', 'summary-subtitle', 'detail-content', 'search-input',
  'add-button', 'refresh-button', 'mobile-back', 'mobile-title', 'activity-status',
  'activity-percent', 'progress-track', 'progress-fill', 'activity-cancel', 'latest-update',
  'module-dialog', 'module-dialog-message', 'module-form', 'icon-url-preview',
  'output-path-preview', 'output-path-note', 'dialog-title', 'save-module-button',
  'advanced-master', 'advanced-master-content', 'advanced-options', 'native-module-note',
  'confirm-dialog', 'confirm-title', 'confirm-message', 'confirm-cancel', 'confirm-accept',
  'toast'
];

const requiredFormNames = [
  'name', 'category', 'iconURL', 'storageLocation', 'outputFolder', 'outputFileName',
  'isEnabled', 'publishesStandalone', 'sourceURL', 'sourceFormat'
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

const selectFieldNames = new Set(['storageLocation', 'outputFolder', 'sourceFormat']);
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
      sourceCount: 1,
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
    moduleOutputFolders: ['', 'Ads/Video'],
    modules: [{
      id: 'module-1',
      name: 'Block HTTPDNS',
      sourceURL: 'https://raw.githubusercontent.com/example/repo/main/block.conf',
      effectiveOriginalSourceURL: 'https://raw.githubusercontent.com/example/repo/main/block.conf',
      sourceFormat: 'quantumultX',
      sourceFormatTitle: 'Quantumult X 重写',
      sourceOriginTitle: '远程 Quantumult X',
      sourceOriginIcon: 'link',
      storageLocation: 'gitHub',
      storageLocationTitle: 'GitHub 模块',
      storageLocationIcon: 'cloud',
      relationshipSummary: 'GitHub 模块 · 远程 Quantumult X',
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
    }]
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
  navigator: { clipboard: { writeText: async () => {} } },
  URL,
  Headers,
  Intl,
  setTimeout: () => 0,
  clearTimeout: () => {},
  setInterval: () => 0,
  clearInterval: () => {},
  fetch: async path => {
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
vm.runInContext(appSource, context, { filename: 'app.js' });

await flushAsync();
await flushAsync();

const list = document.querySelector('#module-list');
const detail = document.querySelector('#detail-content');
const refresh = document.querySelector('#refresh-button');
assert.match(list.innerHTML, /Block HTTPDNS/, 'app.js should render module rows from /api/state');
assert.match(list.innerHTML, /更新失败：原始链接返回 404/, 'sidebar should show failure summary');
assert.match(detail.innerHTML, /管理关系/, 'module detail should render management relationship section');
assert.ok(
  detail.innerHTML.indexOf('最近一次更新失败') >= 0 &&
    detail.innerHTML.indexOf('最近一次更新失败') < detail.innerHTML.indexOf('管理关系'),
  'module detail should expose failure reason before management details'
);
assert.match(detail.innerHTML, /原始地址/, 'module detail should expose original source address');
assert.equal(refresh.disabled, false, 'refresh button should stay enabled when update admission allows it');

document.querySelector('#add-button').dispatch('click');
const form = document.querySelector('#module-form').elements;
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
form.outputFileName.dispatch('input');
assert.equal(
  document.querySelector('#output-path-preview').textContent,
  'Ads/Video/YouTube Ads.sgmodule',
  'local output preview should preserve existing file names'
);

form.publishesStandalone.checked = false;
form.publishesStandalone.dispatch('change');
const note = document.querySelector('#output-path-note');
assert.equal(note.hidden, false);
assert.match(note.textContent, /不会写出这个独立模块文件/);

console.log('Web DOM resource tests passed');

async function flushAsync() {
  await new Promise(resolve => setImmediate(resolve));
}
