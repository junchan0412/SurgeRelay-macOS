const ui = {
  body: document.body,
  list: document.querySelector('#module-list'),
  summaryRow: document.querySelector('#summary-row'),
  summarySubtitle: document.querySelector('#summary-subtitle'),
  detail: document.querySelector('#detail-content'),
  search: document.querySelector('#search-input'),
  filterRow: document.querySelector('#filter-row'),
  failureFilter: document.querySelector('#failure-filter'),
  add: document.querySelector('#add-button'),
  refresh: document.querySelector('#refresh-button'),
  back: document.querySelector('#mobile-back'),
  mobileTitle: document.querySelector('#mobile-title'),
  status: document.querySelector('#activity-status'),
  percent: document.querySelector('#activity-percent'),
  progressTrack: document.querySelector('#progress-track'),
  progressFill: document.querySelector('#progress-fill'),
  cancelActivity: document.querySelector('#activity-cancel'),
  latestUpdate: document.querySelector('#latest-update'),
  moduleDialog: document.querySelector('#module-dialog'),
  moduleDialogMessage: document.querySelector('#module-dialog-message'),
  moduleForm: document.querySelector('#module-form'),
  iconURLPreview: document.querySelector('#icon-url-preview'),
  outputPathPreview: document.querySelector('#output-path-preview'),
  outputPathNote: document.querySelector('#output-path-note'),
  dialogTitle: document.querySelector('#dialog-title'),
  saveModule: document.querySelector('#save-module-button'),
  advancedMaster: document.querySelector('#advanced-master'),
  advancedContent: document.querySelector('#advanced-master-content'),
  advancedOptions: document.querySelector('#advanced-options'),
  nativeNote: document.querySelector('#native-module-note'),
  confirmDialog: document.querySelector('#confirm-dialog'),
  confirmTitle: document.querySelector('#confirm-title'),
  confirmMessage: document.querySelector('#confirm-message'),
  confirmCancel: document.querySelector('#confirm-cancel'),
  confirmAccept: document.querySelector('#confirm-accept'),
  toast: document.querySelector('#toast')
};

const webLogic = window.SurgeRelayWebLogic;
if (!webLogic) throw new Error('web-logic.js must load before app.js');

const webOptions = window.SurgeRelayWebOptions;
if (!webOptions) throw new Error('web-options.js must load before app.js');
const { scriptHubDefaults, advancedGroups } = webOptions;

const webFormat = window.SurgeRelayWebFormat;
if (!webFormat) throw new Error('web-format.js must load before app.js');
const { formatDate, highlightCode } = webFormat;

const webMarkup = window.SurgeRelayWebMarkup;
if (!webMarkup) throw new Error('web-markup.js must load before app.js');
const {
  emptyStateMarkup,
  combinedDetailMarkup,
  moduleDetailMarkup,
  argumentsSectionMarkup
} = webMarkup;

const webSidebar = window.SurgeRelayWebSidebar;
if (!webSidebar) throw new Error('web-sidebar.js must load before app.js');

const webActivity = window.SurgeRelayWebActivity;
if (!webActivity) throw new Error('web-activity.js must load before app.js');

const webAPI = window.SurgeRelayWebAPI;
if (!webAPI) throw new Error('web-api.js must load before app.js');
const apiClient = webAPI.createAPIClient({
  fetch: window.fetch.bind(window),
  Headers: window.Headers,
  location: window.location,
  history: window.history,
  prompt: message => window.prompt(message)
});

const webState = window.SurgeRelayWebState;
if (!webState) throw new Error('web-state.js must load before app.js');

const webEditor = window.SurgeRelayWebEditor;
if (!webEditor) throw new Error('web-editor.js must load before app.js');

const webFeedback = window.SurgeRelayWebFeedback;
if (!webFeedback) throw new Error('web-feedback.js must load before app.js');

const webPreview = window.SurgeRelayWebPreview;
if (!webPreview) throw new Error('web-preview.js must load before app.js');

let state = null;
let selectedID = null;
let detailTab = 'info';
let editingID = null;
let showFailuresOnly = false;
const mobileLayout = window.matchMedia('(max-width: 700px)');
const moduleEditor = webEditor.createModuleEditorController({
  ui,
  logic: webLogic,
  markup: webMarkup,
  scriptHubDefaults,
  advancedGroups,
  document,
  window,
  mobileLayout,
  setTimeout: window.setTimeout.bind(window),
  clearTimeout: window.clearTimeout.bind(window)
});
const feedback = webFeedback.createFeedbackController({
  ui,
  document,
  window,
  navigator,
  setTimeout: window.setTimeout.bind(window),
  clearTimeout: window.clearTimeout.bind(window)
});
const {
  openDialog,
  closeDialog,
  askConfirmation,
  resolveConfirmation,
  resetHorizontalScroll,
  copyText,
  showToast
} = feedback;
const previewController = webPreview.createPreviewController({
  api: (...args) => api(...args),
  document,
  highlightCode,
  askConfirmation,
  showToast
});
const sidebarController = webSidebar.createSidebarController({
  ui,
  getState: () => state,
  getSelectedID: () => selectedID,
  getFailuresOnly: () => showFailuresOnly,
  setFailuresOnly: value => { showFailuresOnly = Boolean(value); }
});
const activityController = webActivity.createActivityController({
  ui,
  getState: () => state
});
const stateEventController = webState.createStateEventController({
  EventSource: window.EventSource,
  document,
  setInterval: window.setInterval.bind(window),
  setTimeout: window.setTimeout.bind(window),
  loadState: (...args) => loadState(...args),
  applyState: (...args) => applyState(...args),
  establishSession: () => apiClient.establishSession()
});

apiClient.initializeAccessToken();
initializeHistoryState();

moduleEditor.installAdvancedOptions();

ui.search.addEventListener('input', sidebarController.render);
ui.failureFilter.addEventListener('click', sidebarController.toggleFailuresOnly);
ui.add.addEventListener('click', () => openEditor());
ui.refresh.addEventListener('click', updateAll);
ui.cancelActivity.addEventListener('click', cancelCurrentWork);
ui.summaryRow.addEventListener('click', () => { if (combinedEnabled()) selectItem('combined'); });
ui.back.addEventListener('click', navigateBackToList);
ui.advancedMaster.addEventListener('click', () => moduleEditor.animateAdvancedResize(ui.advancedMaster.getAttribute('aria-expanded') !== 'true'));
ui.advancedOptions.addEventListener('click', event => {
  const summary = event.target.closest('.option-group > summary');
  if (!summary) return;
  event.preventDefault();
  moduleEditor.animateOptionGroup(summary.parentElement);
});
ui.moduleForm.elements.sourceURL.addEventListener('input', () => {
  moduleEditor.updateNativeModuleState();
  updateOutputPathPreview();
  moduleEditor.scheduleNameLookup({ api, updateOutputPathPreview });
});
ui.moduleForm.elements.sourceFormat.addEventListener('change', moduleEditor.updateNativeModuleState);
ui.moduleForm.elements.name.addEventListener('input', event => {
  moduleEditor.handleNameInput(event.target.value);
  updateOutputPathPreview();
});
ui.moduleForm.elements.outputFolder.addEventListener('change', updateOutputPathPreview);
ui.moduleForm.elements.storageLocation.addEventListener('change', updateOutputPathPreview);
ui.moduleForm.elements.outputFileName.addEventListener('input', updateOutputPathPreview);
ui.moduleForm.elements.iconURL.addEventListener('input', moduleEditor.updateIconURLPreview);
ui.moduleForm.elements.publishesStandalone.addEventListener('change', updateOutputPathPreview);
document.querySelectorAll('.close-module-dialog').forEach(button => button.addEventListener('click', () => closeDialog(ui.moduleDialog)));
ui.moduleDialog.addEventListener('click', async event => {
  const copyButton = event.target.closest('[data-action="copy-output-path"]');
  if (copyButton) {
    await copyText(ui.outputPathPreview?.textContent || '', copyButton);
    return;
  }
  if (event.target === ui.moduleDialog) closeDialog(ui.moduleDialog);
});
ui.moduleForm.addEventListener('submit', saveModule);
ui.confirmCancel.addEventListener('click', () => resolveConfirmation(false));
ui.confirmAccept.addEventListener('click', () => resolveConfirmation(true));
ui.confirmDialog.addEventListener('click', event => { if (event.target === ui.confirmDialog) resolveConfirmation(false); });
ui.list.addEventListener('click', handleListClick);
ui.list.addEventListener('change', handleListChange);
ui.list.addEventListener('keydown', event => {
  const row = event.target.closest('.module-row');
  if (row && (event.key === 'Enter' || event.key === ' ')) { event.preventDefault(); selectItem(row.dataset.id); }
});
ui.detail.addEventListener('click', handleDetailClick);
ui.detail.addEventListener('change', handleDetailChange);
window.addEventListener('popstate', handleHistoryNavigation);

apiClient.establishSession()
  .catch(error => showToast(error.message, true))
  .finally(() => loadState(true, true).finally(startStateEvents));

function api(path, options = {}) {
  return apiClient.request(path, options);
}

async function loadState(initial = false, renderCurrentDetail = false) {
  try {
    const next = await api('/api/state');
    applyState(next, initial, renderCurrentDetail);
  } catch (error) { showToast(error.message, true); }
}

function applyState(next, initial = false, renderCurrentDetail = false) {
    const previous = state;
    const previousSelectedID = selectedID;
    state = next;
    if (initial) {
      const initialSelection = webState.resolveInitialSelection(next, {
        requestedModuleID: webState.moduleIDFromLocation(location),
        isMobile: mobileLayout.matches
      });
      selectedID = initialSelection.selectedID;
      ui.body.classList.toggle('has-selection', initialSelection.hasSelection);
    }
    const selectionChanged = normalizeSelection(next) || previousSelectedID !== selectedID;
    ui.body.classList.toggle('has-selection', Boolean(selectedID));
    if (initial || renderCurrentDetail || selectionChanged) {
      sidebarController.render();
      activityController.render();
      renderDetail(false);
    } else {
      patchLiveState(previous, next);
      activityController.render();
    }
}

function combinedEnabled(snapshot = state) {
  return webState.combinedEnabled(snapshot);
}

function fallbackSelection(snapshot = state) {
  return webState.fallbackSelection(snapshot, mobileLayout.matches);
}

function normalizeSelection(snapshot = state) {
  const result = webState.normalizeSelection(snapshot, selectedID, mobileLayout.matches);
  selectedID = result.selectedID;
  return result.changed;
}

function startStateEvents() {
  stateEventController.start();
}

function patchLiveState(previous, next) {
  if (!previous) {
    sidebarController.render();
    return;
  }

  const previousList = webLogic.sidebarListSignature(previous);
  const nextList = webLogic.sidebarListSignature(next);
  if (previousList !== nextList) sidebarController.render(); else sidebarController.patchLive();

  if (detailTab !== 'info') return;
  if (selectedID === 'combined') {
    if (!next.combined.isEnabled) return;
    patchDetailValue('包含来源', `${next.combined.enabledCount} / ${next.combined.sourceCount}`);
    patchDetailValue('最新更新', formatDate(next.combined.lastUpdatedAt, '尚未更新'));
    return;
  }

  const module = next.modules.find(item => item.id === selectedID);
  if (!module) return;
  const previousModule = previous.modules.find(item => item.id === selectedID);
  if (webLogic.metadataRowPresenceChanged(previousModule, module)) {
    renderDetail(false);
    return;
  }
  patchDetailValue('更新状态', webLogic.moduleStatusTitle(module));
  patchDetailValue('转换前来源', module.sourceOriginTitle || module.sourceFormatTitle);
  patchDetailValue('来源格式', module.sourceFormatTitle);
  if (next.combined.isEnabled) patchDetailValue('汇总订阅', next.combined.subscriptionURL || '等待发布配置');
  patchDetailValue('创建时间', formatDate(module.createdAt, '—'));
  patchDetailValue('上次更新', formatDate(module.lastUpdatedAt, '从未更新'));
  patchDetailValue('来源检查', formatDate(module.sourceCheckedAt, '尚未检查'));
  patchDetailValue('内容 hash', module.contentHash ? module.contentHash.slice(0, 12) : '尚未生成');
  patchDetailValue('转换引擎', module.conversionEngineRevision ? module.conversionEngineRevision.slice(0, 12) : '原生 Surge 模块');
}

function patchDetailValue(label, value) {
  const row = [...ui.detail.querySelectorAll('.detail-row')]
    .find(item => item.querySelector('.detail-label span:last-child')?.textContent === label);
  const target = row?.querySelector('.detail-value');
  if (target && target.textContent !== value) target.textContent = value;
}

function renderDetail(animate = true) {
  if (!state || !selectedID) { setDetailHTML(emptyStateMarkup('sidebar.left', '选择一个模块'), animate); return; }
  if (selectedID === 'combined') {
    if (!state.combined.isEnabled) { normalizeSelection(); renderDetail(animate); return; }
    ui.mobileTitle.textContent = state.combined.name;
    renderCombinedDetail(animate);
  }
  else {
    const module = state.modules.find(item => item.id === selectedID);
    if (module) {
      ui.mobileTitle.textContent = module.name;
      renderModuleDetail(module, animate);
    }
  }
}

function setDetailHTML(content, animate = true) {
  ui.detail.innerHTML = `<div class="detail-stage ${animate ? 'page-enter' : ''}">${content}</div>`;
}

function renderCombinedDetail(animate = true) {
  const combined = state.combined;
  setDetailHTML(combinedDetailMarkup(combined, {
    selectedTab: detailTab,
    latestGitHubPublish: state.activity?.latestGitHubPublish
  }), animate);
  if (!combined.isEnabled) return;
  if (detailTab === 'preview') {
    previewController.loadPreview('/api/combined/preview', false);
  }
}

function renderModuleDetail(module, animate = true) {
  setDetailHTML(moduleDetailMarkup(module, {
    selectedTab: detailTab,
    combined: state.combined
  }), animate);
  if (detailTab === 'preview') {
    previewController.loadPreview(`/api/modules/${module.id}/preview`, true);
    return;
  }
  loadArguments(module);
}

async function loadArguments(module) {
  try {
    const payload = await api(`/api/modules/${module.id}/arguments`);
    if (selectedID !== module.id || detailTab !== 'info') return;
    const target = document.querySelector('#arguments-section');
    if (!target || !payload.arguments.length) return;
    target.innerHTML = argumentsSectionMarkup(payload);
  } catch (_) {}
}

function updateOutputPathPreview() {
  moduleEditor.updateOutputPathPreview({ state, editingID });
}

function handleListClick(event) {
  if (event.target.closest('.module-toggle')) return;
  const row = event.target.closest('.module-row');
  if (row) selectItem(row.dataset.id);
}

async function handleListChange(event) {
  const input = event.target.closest('[data-module-toggle]');
  if (!input) return;
  if (!combinedEnabled()) return;
  try { await api(`/api/modules/${input.dataset.moduleToggle}/enabled`, { method: 'POST', json: { enabled: input.checked } }); await loadState(false, true); }
  catch (error) { input.checked = !input.checked; showToast(error.message, true); }
}

async function handleDetailClick(event) {
  const source = event.target.closest('[data-action]');
  const action = source?.dataset.action;
  if (!action) return;
  const module = state.modules.find(item => item.id === selectedID);
  switch (action) {
  case 'tab-info': detailTab = 'info'; renderDetail(false); break;
  case 'tab-preview': detailTab = 'preview'; renderDetail(false); break;
  case 'edit': if (module) openEditor(module); break;
  case 'delete': if (module) await deleteModule(module); break;
  case 'copy': await copyText(source.dataset.value, source); break;
  case 'copy-preview': await copyText(previewController.text, source); break;
  case 'save-preview': if (module) await previewController.savePreview(module); break;
  case 'restore-preview': if (module) await previewController.restorePreview(module); break;
  case 'reset-arguments': if (module) await resetArguments(module); break;
  case 'accept-override': if (module) await acceptOverride(module); break;
  }
}

async function acceptOverride(module) {
  try {
    const result = await api(`/api/modules/${module.id}/override-conflict`, { method: 'POST' });
    showToast(result.message);
    await loadState(false, true);
  } catch (error) { showToast(error.message, true); }
}

async function handleDetailChange(event) {
  const input = event.target.closest('[data-argument-key]');
  if (!input || selectedID === 'combined') return;
  const value = input.type === 'checkbox' ? String(input.checked) : input.value;
  try { await api(`/api/modules/${selectedID}/arguments`, { method: 'PUT', json: { key: input.dataset.argumentKey, value } }); showToast('模块参数已更新'); }
  catch (error) { showToast(error.message, true); }
}

function selectItem(id, pushHistory = true) {
  if (!state) return;
  if (id === 'combined' && !state.combined.isEnabled) id = fallbackSelection();
  if (id !== 'combined' && !state.modules.some(module => module.id === id)) id = fallbackSelection();
  if (!id) { showModuleList(pushHistory); return; }
  const cameFromList = mobileLayout.matches && !ui.body.classList.contains('has-selection');
  selectedID = id; detailTab = 'info'; ui.body.classList.add('has-selection');
  resetHorizontalScroll();
  if (pushHistory) {
    const entry = webState.detailHistoryEntry(location, id, cameFromList);
    history.pushState(entry.state, '', entry.url);
  }
  sidebarController.render(); renderDetail(false);
}

function initializeHistoryState() {
  const transition = webState.initialHistoryTransition(location, history.state);
  if (!transition) return;
  history.replaceState(transition.replace.state, '', transition.replace.url);
  if (transition.push) history.pushState(transition.push.state, '', transition.push.url);
}

function showModuleList(replaceHistory = false) {
  selectedID = null;
  detailTab = 'info';
  ui.body.classList.remove('has-selection');
  resetHorizontalScroll();
  if (replaceHistory) {
    const entry = webState.listHistoryEntry(location);
    history.replaceState(entry.state, '', entry.url);
  }
  sidebarController.render();
  renderDetail(false);
}

function navigateBackToList() {
  if (!mobileLayout.matches) return;
  if (webState.mobileBackAction(history.state) === 'back') history.back();
  else showModuleList(true);
}

function handleHistoryNavigation(event) {
  const target = webState.historyNavigationTarget(location, event.state, mobileLayout.matches, fallbackSelection());
  if (target.action === 'show-list') {
    showModuleList(false);
    return;
  }
  selectItem(target.moduleID, false);
}

function openEditor(module = null) {
  const editorState = moduleEditor.populateModuleForm(module, {
    state,
    combinedEnabled: combinedEnabled()
  });
  editingID = editorState.editingID;
  openDialog(ui.moduleDialog);
  const formContent = ui.moduleDialog.querySelector('.form-content');
  if (formContent) formContent.scrollTop = 0;
  setTimeout(() => editorState.focusTarget?.focus(), 180);
}

async function saveModule(event) {
  event.preventDefault();
  const form = ui.moduleForm.elements;
  const existingModule = editingID ? state.modules.find(module => module.id === editingID) : null;
  const editorFields = moduleEditor.collectModuleFields();
  const validation = webLogic.validateModuleEditorFields(editorFields);
  if (validation) {
    ui.moduleDialogMessage.textContent = validation.message;
    ui.moduleDialogMessage.hidden = false;
    form[validation.field]?.focus();
    return;
  }
  const payload = webLogic.moduleEditorPayload(editorFields, {
    combinedEnabled: combinedEnabled(),
    existingModule
  });
  ui.saveModule.disabled = true;
  try {
    const path = editingID ? `/api/modules/${editingID}` : '/api/modules';
    const result = await api(path, { method: editingID ? 'PUT' : 'POST', json: payload });
    await closeDialog(ui.moduleDialog);
    showToast(result.message);
    await loadState(false, true);
  } catch (error) {
    ui.moduleDialogMessage.textContent = error.message;
    ui.moduleDialogMessage.hidden = false;
  }
  finally { ui.saveModule.disabled = false; }
}

async function updateAll() {
  try { const result = await api('/api/update-all', { method: 'POST' }); showToast(result.message); await loadState(false, false); }
  catch (error) { showToast(error.message, true); }
}

async function cancelCurrentWork() {
  try { const result = await api('/api/cancel-work', { method: 'POST' }); showToast(result.message); await loadState(false, false); }
  catch (error) { showToast(error.message, true); }
}

async function deleteModule(module) {
  const message = combinedEnabled()
    ? `“${module.name}”会从 Surge Relay 和总模块中移除。`
    : `“${module.name}”会从 Surge Relay 管理列表中移除。`;
  const accepted = await askConfirmation('删除模块？', message, '删除');
  if (!accepted) return;
  try {
    const result = await api(`/api/modules/${module.id}`, { method: 'DELETE' });
    selectedID = fallbackSelection({ ...state, modules: state.modules.filter(item => item.id !== module.id) });
    showToast(result.message);
    await loadState(false, true);
  }
  catch (error) { showToast(error.message, true); }
}

async function resetArguments(module) {
  try { const result = await api(`/api/modules/${module.id}/arguments`, { method: 'DELETE' }); showToast(result.message); renderModuleDetail(module, true); }
  catch (error) { showToast(error.message, true); }
}
