import assert from 'node:assert/strict';
import { detailHelpers, logic, markup } from './harness.mjs';

function createDOMStub() {
  const detail = {
    innerHTML: '',
    querySelectorAll() { return []; }
  };
  return {
    body: {},
    detail,
    mobileTitle: { textContent: '' }
  };
}

{
  const queue = { innerHTML: '' };
  const ui = createDOMStub();
  ui.detail.querySelector = selector => selector === '#pending-module-saves' ? queue : null;
  let finishHistory;
  let historyRequests = 0;
  const state = {
    modules: [], workspace: {},
    activity: { pendingModuleSaves: [
      { id: 'first', name: '<First>', isActive: true },
      { id: 'second', name: 'Second', errorMessage: '目标写入失败' }
    ] }
  };
  const { controller, setState } = createController({ state, selectedID: 'activity', inject: {
    ui, api: () => { historyRequests += 1; return new Promise(resolve => { finishHistory = resolve; }); }
  } });
  controller.setTab('preview');
  controller.renderDetail(false);
  assert.match(ui.detail.innerHTML, /id="pending-module-saves"/);
  assert.match(ui.detail.innerHTML, /&lt;First&gt;/);
  assert.ok(ui.detail.innerHTML.indexOf('&lt;First&gt;') < ui.detail.innerHTML.indexOf('Second'), 'queue retains submission order');
  assert.match(ui.detail.innerHTML, /data-save-id="first" disabled/);
  assert.match(ui.detail.innerHTML, /data-action="retry-module-save" data-save-id="second"/);
  const updated = { ...state, activity: { pendingModuleSaves: [{ id: 'second', name: 'Second', isActive: true }] } };
  setState(updated);
  controller.patchLiveDetail(state, updated);
  assert.match(queue.innerHTML, /正在保存/);
  assert.doesNotMatch(queue.innerHTML, /First|重试/);
  assert.equal(historyRequests, 1, 'queue-only state updates do not reload history');
  setState({ ...updated, activity: { pendingModuleSaves: [] } });
  controller.patchPendingModuleSaves();
  assert.match(queue.innerHTML, /没有待保存的配置/);
  finishHistory([]);
  await Promise.resolve();
  assert.match(ui.detail.innerHTML, /没有待保存的配置/, 'late history response uses the current queue');
}

function createController(overrides = {}) {
  let state = overrides.state || null;
  let selectedID = overrides.selectedID ?? null;
  const previewCalls = [];
  const controller = detailHelpers.createDetailController({
    ui: createDOMStub(),
    markup,
    logic,
    previewController: { loadPreview: (...args) => previewCalls.push(args) },
    api: async () => ({ arguments: [] }),
    formatDate: value => String(value ?? ''),
    getState: () => state,
    getSelectedID: () => selectedID,
    normalizeSelection: () => {
      if (selectedID === 'combined') selectedID = null;
    },
    ...overrides.inject
  });
  return {
    controller,
    previewCalls,
    setState(next) { state = next; },
    setSelected(id) { selectedID = id; }
  };
}

{
  const { controller } = createController();
  assert.equal(controller.getTab(), 'info', 'detail tab should default to info');
  controller.setTab('preview');
  assert.equal(controller.getTab(), 'preview');
  controller.setTab('nonsense');
  assert.equal(controller.getTab(), 'preview', 'unknown tabs should be ignored');
  let focusedTab = null;
  const keyboard = createController({ inject: { ui: { detail: { querySelector: selector => ({ focus() { focusedTab = selector; } }) }, mobileTitle: {} } } }).controller;
  const event = key => ({ key, target: { closest: () => ({}) }, preventDefault() {} });
  keyboard.handleTabKeydown(event('ArrowRight'));
  assert.equal(keyboard.getTab(), 'preview');
  assert.equal(focusedTab, '#detail-tab-preview');
  keyboard.handleTabKeydown(event('Home'));
  assert.equal(keyboard.getTab(), 'info');
  assert.equal(focusedTab, '#detail-tab-info');
}

{
  const module = {
    id: 'm1',
    name: 'Demo Module',
    statusTitle: 'idle',
    initialSourceTitle: '订阅来源',
    sourceFormatTitle: 'Surge',
    createdAt: '2026-08-01T00:00:00Z',
    lastUpdatedAt: '2026-08-02T00:00:00Z',
    sourceCheckedAt: null,
    contentHash: 'abcdef1234567890',
    conversionEngineRevision: null
  };
  const combined = { isEnabled: true, enabledCount: 2, sourceCount: 5, lastUpdatedAt: '2026-08-03T00:00:00Z', name: '总模块' };
  const { controller, setState, setSelected } = createController({
    state: { modules: [module], combined, activity: {} },
    selectedID: 'm1'
  });

  controller.renderDetail(false);
  controller.setTab('preview');
  controller.renderDetail(false);

  // 切回 info 页签后，live patch 应静默返回而不是抛错。
  controller.setTab('info');
  const next = {
    modules: [{ ...module, lastUpdatedAt: '2026-08-04T00:00:00Z' }],
    combined
  };
  controller.patchLiveDetail({ modules: [module], combined }, next);
  assert.equal(controller.getTab(), 'info');

}

console.log('web-detail behavior tests passed');

{
  const previous = { id: 'live', contentHash: 'old-content-hash', sourceContentHash: 'old-source-hash', sourceETag: 'old-etag' };
  const next = { ...previous, contentHash: 'new-content-hash', sourceContentHash: 'new-source-hash', sourceETag: 'new-etag' };
  const nodes = new Map(['内容 hash', '来源 hash', '来源 ETag'].map(label => [label, {
    label: { textContent: label }, text: { textContent: 'old' }, copy: { dataset: { value: 'old' } }
  }]));
  const rows = [...nodes.values()].map(node => ({ querySelector(selector) {
    if (selector === '.detail-label span:last-child') return node.label;
    if (selector === '.detail-value-text') return node.text;
    if (selector === '.detail-copy') return node.copy;
    return null;
  }}));
  const { controller } = createController({
    state: { modules: [next], combined: {} }, selectedID: 'live',
    inject: { document: { querySelector: () => null }, ui: { detail: { querySelectorAll: () => rows, querySelector: () => null }, mobileTitle: { textContent: '' } } }
  });
  controller.patchLiveDetail({ modules: [previous], combined: {} }, { modules: [next], combined: {} });
  assert.equal(nodes.get('内容 hash').copy.dataset.value, 'new-content-hash');
  assert.equal(nodes.get('来源 hash').copy.dataset.value, 'new-source-hash');
  assert.equal(nodes.get('来源 ETag').text.textContent, 'new-etag');
  assert.equal(nodes.get('来源 ETag').copy.dataset.value, 'new-etag');
  assert.equal(logic.metadataRowPresenceChanged(previous, { ...next, hasOverrideConflict: true }), true);
}
