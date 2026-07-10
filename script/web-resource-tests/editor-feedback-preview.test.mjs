import assert from 'node:assert/strict';
import { editorHelpers, feedbackHelpers, logic, markup, options, previewHelpers } from './harness.mjs';

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
assert.deepEqual(
  editorController.outputFoldersForStorage({
    moduleEditor: {
      localOutputFolders: ['', 'Local'],
      githubOutputFolders: ['', 'Remote']
    }
  }, 'local'),
  ['', 'Local']
);
editorFormElements.storageLocation.value = 'gitHub';
editorController.refreshOutputFolders({
  moduleEditor: {
    localOutputFolders: ['', 'Local'],
    githubOutputFolders: ['', 'Remote']
  }
}, 'Remote');
assert.equal(editorFormElements.outputFolder.value, 'Remote');
assert.match(editorFormElements.outputFolder.innerHTML, /value="Remote">Remote/);
editorFormElements.storageLocation.value = 'local';
editorFormElements.outputFolder.value = 'Folder';
editorFormElements.sourceURL.value = 'https://example.com/source.sgmodule';
const outputPreview = editorController.updateOutputPathPreview({
  state: {
    combined: { fileName: 'Surge Relay' },
    moduleEditor: { publishToLocal: true, publishToGitHub: true },
    modules: [{ id: 'other', name: 'Other Module', publishedRelativePath: 'Folder/Demo Module.sgmodule' }]
  },
  editingID: null
});
assert.equal(outputPreview.path, 'Folder/Demo Module.sgmodule');
assert.equal(outputPreview.notice.warning, true);
assert.match(editorUI.outputPathNote.textContent, /Other Module/);
assert.equal(editorUI.outputPathNote.hidden, false);
assert.equal(editorUI.outputPathNote.classList.contains('warning'), true);
const disabledTargetPreview = editorController.updateOutputPathPreview({
  state: {
    combined: { fileName: 'Surge Relay' },
    moduleEditor: { publishToLocal: false, publishToGitHub: true },
    modules: []
  },
  editingID: null
});
assert.equal(disabledTargetPreview.notice.warning, true);
assert.match(disabledTargetPreview.notice.message, /发布到本地.*尚未开启/);
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
