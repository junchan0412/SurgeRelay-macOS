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

  setSelected('combined');
  controller.patchLiveDetail({ modules: [module], combined }, { modules: [module], combined });
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
