import assert from 'node:assert/strict';
import { sidebarHelpers, previewHelpers } from './harness.mjs';

const documentRef = { activeElement: null, querySelector: () => null };
let listHTML = '';
let listWrites = 0;
let rowWrites = 0;
let nodes = new Map();
function makeRow(html) {
  const id = html.match(/data-id="([^"]+)"/)[1];
  const classes = new Set(html.match(/class="([^"]+)"/)[1].split(' '));
  const row = {
    dataset: { id },
    classList: { toggle(name, value) { value ? classes.add(name) : classes.delete(name); }, contains: name => classes.has(name) },
    scrollIntoView() { this.scrolled = true; },
    querySelector: selector => selector === '.module-open' ? button : selector === '[data-module-toggle]' ? toggle : null,
    set outerHTML(value) {
      rowWrites++;
      listHTML = listHTML.replace(html, value);
      if (documentRef.activeElement?.closest?.('.module-row') === row) documentRef.activeElement = null;
      nodes.set(id, makeRow(value));
    }
  };
  const button = {
    attributes: {},
    setAttribute(name, value) { this.attributes[name] = value; },
    focus() { documentRef.activeElement = this; },
    closest: selector => selector === '.module-row' ? row : null,
    matches: () => false
  };
  const toggle = {
    checked: false,
    focus() { documentRef.activeElement = this; },
    closest: selector => selector === '.module-row' ? row : selector === '.module-toggle' ? {} : null,
    matches: selector => selector === '[data-module-toggle]'
  };
  return row;
}
const ui = {
  search: { value: '', focus() { documentRef.activeElement = this; }, select() { this.selected = true; } },
  clearSearch: { hidden: true },
  searchStatus: { textContent: '' },
  filterRow: {},
  failureFilter: { setAttribute() {}, querySelector: () => null },
  summaryRow: { classList: { toggle() {} }, setAttribute() {} },
  summarySubtitle: {},
  list: {
    get innerHTML() { return listHTML; },
    set innerHTML(value) {
      listWrites++;
      listHTML = value;
      nodes = new Map([...value.matchAll(/<div class="module-row[\s\S]*?<\/div>/g)].map(([html]) => {
        const row = makeRow(html);
        return [row.dataset.id, row];
      }));
    },
    querySelectorAll: () => [...nodes.values()],
    querySelector: selector => nodes.get(selector.match(/data-id="([^"]+)"/)?.[1])
  }
};
let selectedID = 'module-0';
let state = {
  combined: { isEnabled: true, enabledCount: 200 },
  modules: Array.from({ length: 200 }, (_, index) => ({ id: `module-${index}`, name: `Module ${index}`, isEnabled: true, publishesStandalone: true, state: 'current', stateTitle: '已是最新' }))
};
let activatedID = null;
const sidebar = sidebarHelpers.createSidebarController({ ui, document: documentRef, getState: () => state, getSelectedID: () => selectedID, selectItem: id => { activatedID = id; } });
sidebar.render();
const untouchedRow = nodes.get('module-10');
selectedID = 'module-2';
sidebar.render();
assert.equal(listWrites, 1, 'selecting a module must reuse the existing list DOM');
assert.equal(nodes.get('module-10'), untouchedRow);
assert.equal(nodes.get('module-0').classList.contains('selected'), false);
assert.equal(nodes.get('module-2').querySelector('.module-open').attributes['aria-current'], 'page');
nodes.get('module-2').querySelector('[data-module-toggle]').focus();
state = { ...state, modules: state.modules.map(module => module.id === 'module-2' ? { ...module, state: 'failed', stateTitle: '更新失败', lastError: '连接超时' } : module) };
sidebar.render();
assert.equal(rowWrites, 1, 'live updates replace only the changed module row');
assert.equal(listWrites, 1);
assert.equal(nodes.get('module-10'), untouchedRow);
assert.equal(documentRef.activeElement, nodes.get('module-2').querySelector('[data-module-toggle]'), 'live patches restore the focused switch');
const key = (key, target = ui.search, extra = {}) => ({ key, target, prevented: false, preventDefault() { this.prevented = true; }, ...extra });
sidebar.handleSearchKeydown(key('ArrowDown'));
assert.equal(documentRef.activeElement, nodes.get('module-0').querySelector('.module-open'));
sidebar.handleListKeydown(key('End', documentRef.activeElement));
assert.equal(documentRef.activeElement, nodes.get('module-199').querySelector('.module-open'));
sidebar.handleListKeydown(key('Home', documentRef.activeElement));
assert.equal(documentRef.activeElement, nodes.get('module-0').querySelector('.module-open'));
sidebar.handleListKeydown(key('ArrowDown', documentRef.activeElement));
assert.equal(documentRef.activeElement, nodes.get('module-1').querySelector('.module-open'));
sidebar.handleListKeydown(key('Escape', documentRef.activeElement));
assert.equal(documentRef.activeElement, ui.search);
ui.search.value = 'Module 199';
sidebar.render();
assert.match(ui.searchStatus.textContent, /找到 1 个模块，共 200 个/);
assert.equal(ui.clearSearch.hidden, false);
sidebar.handleSearchKeydown(key('Enter'));
assert.equal(activatedID, 'module-199');
sidebar.handleSearchKeydown(key('Escape', ui.search, { isComposing: true }));
assert.equal(ui.search.value, 'Module 199', 'IME confirmation keys must not alter the search');
sidebar.handleSearchKeydown(key('Escape'));
assert.equal(ui.search.value, '');
assert.equal(nodes.size, 200);

const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const flush = () => new Promise(resolve => setImmediate(resolve));
const elements = {
  '#code-editor': { value: '', selectionStart: 0, selectionEnd: 0, scrollTop: 0, scrollLeft: 0, addEventListener(name, callback) { this[name] = callback; }, setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end; } },
  '#code-view': { innerHTML: '', textContent: '' },
  '#preview-status': { dataset: {}, textContent: '' },
  '#preview-message': {},
  '[data-action="save-preview"]': {},
  '[data-action="restore-preview"]': {},
  '[data-action="copy-preview"]': {},
  '[data-action="retry-preview"]': {}
};
let mutation = deferred();
let mutations = 0;
let failLoad = false;
let largePreview = false;
let highlights = 0;
const largeText = '[Rule]\n' + 'DOMAIN,example.com,DIRECT\n'.repeat(12000);
const preview = previewHelpers.createPreviewController({
  document: { querySelector: selector => elements[selector] || null },
  api: async (path, options = {}) => {
    if (options.method) { mutations++; return mutation.promise; }
    if (failLoad) throw new Error('连接中断');
    return largePreview ? largeText : `saved:${path}`;
  },
  highlightCode: text => { highlights++; return text; },
  askConfirmation: async () => true
});
const editor = elements['#code-editor'];
const input = text => { editor.value = text; editor.input(); };
const path = '/api/modules/demo/preview';
await preview.loadPreview(path, true);
assert.equal(elements['#preview-status'].textContent, '已保存');
input('first edit');
assert.equal(elements['#preview-status'].textContent, '未保存');
const saving = preview.savePreview({ id: 'demo' });
await preview.savePreview({ id: 'demo' });
await preview.restorePreview({ id: 'demo', name: 'Demo' });
assert.equal(mutations, 1, 'a pending save blocks duplicate saves and overlapping restores');
assert.equal(elements['[data-action="save-preview"]'].disabled, true);
input('typed during save');
mutation.resolve({ message: 'saved' });
await saving;
assert.equal(preview.savedText, 'first edit');
assert.equal(preview.text, 'typed during save');
assert.equal(elements['[data-action="save-preview"]'].disabled, false);

mutation = deferred();
const savingBeforeNavigation = preview.savePreview({ id: 'demo' });
input('first edit');
editor.selectionStart = 3;
editor.selectionEnd = 7;
editor.scrollTop = 140;
preview.deactivate();
await preview.loadPreview('/api/modules/other/preview', true);
mutation.resolve({ message: 'saved' });
await savingBeforeNavigation;
await preview.loadPreview(path, true);
assert.equal(editor.value, 'first edit', 'undoing to the previous baseline during a save survives navigation');
assert.equal(preview.savedText, 'typed during save');
assert.equal(editor.selectionStart, 3);
assert.equal(editor.selectionEnd, 7);
assert.equal(editor.scrollTop, 140);

mutation = deferred();
const restoring = preview.restorePreview({ id: 'demo', name: 'Demo' });
await flush();
assert.equal(elements['#preview-status'].textContent, '正在恢复…');
input('typed during restore');
mutation.resolve('fresh converted output');
await restoring;
assert.equal(editor.value, 'typed during restore');
assert.equal(preview.savedText, 'fresh converted output');
assert.equal(preview.hasUnsavedChanges, true);

failLoad = true;
await preview.loadPreview('/api/modules/unavailable/preview', true);
assert.equal(editor.disabled, true);
assert.equal(elements['[data-action="copy-preview"]'].disabled, true);
assert.equal(elements['[data-action="retry-preview"]'].hidden, false);
assert.match(elements['#preview-message'].textContent, /连接中断/);
failLoad = false;
await preview.retryPreview();
assert.equal(editor.disabled, false);
assert.equal(elements['[data-action="retry-preview"]'].hidden, true);
assert.equal(elements['[data-action="copy-preview"]'].disabled, false);
largePreview = true;
await preview.loadPreview('/api/combined/preview', false);
assert.equal(highlights, 0, 'large read-only previews avoid generating thousands of syntax nodes');
assert.equal(elements['#code-view'].textContent, largeText, 'plain preview retains the complete content');
assert.equal(preview.text, largeText);
assert.match(elements['#preview-status'].textContent, /纯文本/);

const staleResponse = deferred();
const stalePreview = previewHelpers.createPreviewController({ api: () => staleResponse.promise, document: { querySelector: selector => elements[selector] || null } });
const staleLoad = stalePreview.loadPreview('/api/modules/stale/preview', true);
stalePreview.deactivate();
editor.value = 'another screen';
staleResponse.resolve('obsolete response');
await staleLoad;
assert.equal(editor.value, 'another screen', 'leaving preview invalidates a response before it can write to a later screen');
