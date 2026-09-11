const ui = {
  body: document.body,
  sidebar: document.querySelector('.sidebar'),
  detailPane: document.querySelector('#detail'),
  list: document.querySelector('#module-list'),
  summaryRow: document.querySelector('#summary-row'),
  overview: document.querySelector('#overview-button'),
  history: document.querySelector('#history-button'),
  connection: document.querySelector('#connection-status'),
  summarySubtitle: document.querySelector('#summary-subtitle'),
  detail: document.querySelector('#detail-content'),
  search: document.querySelector('#search-input'),
  clearSearch: document.querySelector('#clear-search'),
  searchStatus: document.querySelector('#search-status'),
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

const webDetail = window.SurgeRelayWebDetail;
if (!webDetail) throw new Error('web-detail.js must load before app.js');

let state = null;
let selectedID = null;
let editingID = null;
let showFailuresOnly = false;
let stateRevision = 0;
let stateRequest = 0;
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
const detailController = webDetail.createDetailController({
  ui,
  markup: webMarkup,
  logic: webLogic,
  previewController,
  api: (...args) => api(...args),
  document,
  formatDate,
  getState: () => state,
  getSelectedID: () => selectedID,
  normalizeSelection: () => { normalizeSelection(); }
});
const renderDetail = (animate = true) => detailController.renderDetail(animate);
const sidebarController = webSidebar.createSidebarController({
  ui,
  document,
  selectItem,
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
  clearInterval: window.clearInterval.bind(window),
  setTimeout: window.setTimeout.bind(window),
  clearTimeout: window.clearTimeout.bind(window),
  loadState: (...args) => loadState(...args),
  applyState: (...args) => applyState(...args),
  applyActivity: activity => applyActivity(activity),
  fetchActivity: () => api('/api/activity'),
  isWorking: () => Boolean(state?.activity?.isWorking),
  establishSession: () => apiClient.establishSession(),
  onConnectionChange: status => {
    if (!ui.connection) return;
    ui.connection.textContent = ({ connected: '已连接', connecting: '连接中', reconnecting: '正在重连', polling: '定时同步', paused: '已暂停' })[status];
    ui.connection.dataset.status = status;
  }
});

apiClient.initializeAccessToken();
initializeHistoryState();

moduleEditor.installAdvancedOptions();

ui.search.addEventListener('input', sidebarController.render);
ui.search.addEventListener('keydown', sidebarController.handleSearchKeydown);
ui.clearSearch?.addEventListener('click', sidebarController.clearSearch);
ui.failureFilter.addEventListener('click', sidebarController.toggleFailuresOnly);
ui.add.addEventListener('click', () => openEditor());
ui.refresh.addEventListener('click', updateAll);
ui.cancelActivity.addEventListener('click', cancelCurrentWork);
ui.summaryRow.addEventListener('click', () => { if (combinedEnabled()) selectItem('combined'); });
ui.overview?.addEventListener('click', () => selectItem('overview'));
ui.history?.addEventListener('click', () => selectItem('activity'));
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
ui.moduleForm.elements.storageLocation.addEventListener('change', () => {
  moduleEditor.refreshOutputFolders(state);
  updateOutputPathPreview();
});
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
ui.moduleDialog.addEventListener('cancel', event => { event.preventDefault(); closeDialog(ui.moduleDialog); });
ui.moduleForm.addEventListener('submit', saveModule);
ui.confirmCancel.addEventListener('click', () => resolveConfirmation(false));
ui.confirmAccept.addEventListener('click', () => resolveConfirmation(true));
ui.confirmDialog.addEventListener('click', event => { if (event.target === ui.confirmDialog) resolveConfirmation(false); });
ui.list.addEventListener('click', handleListClick);
ui.list.addEventListener('change', handleListChange);
ui.list.addEventListener('keydown', sidebarController.handleListKeydown);
ui.detail.addEventListener('click', handleDetailClick);
ui.detail.addEventListener('change', handleDetailChange);
ui.detail.addEventListener('keydown', detailController.handleTabKeydown);
window.addEventListener('popstate', handleHistoryNavigation);
window.addEventListener('keydown', event => {
  if (event.defaultPrevented || event.isComposing || ui.moduleDialog.open || ui.confirmDialog.open) return;
  const command = (event.metaKey || event.ctrlKey) && !event.altKey;
  const editable = event.target?.closest?.('input, textarea, select, [contenteditable="true"]');
  if ((command && event.key.toLowerCase() === 'k') || (!command && !event.altKey && event.key === '/' && !editable)) {
    event.preventDefault();
    if (mobileLayout.matches && ui.body.classList.contains('has-selection')) showModuleList(true);
    ui.search.focus();
    ui.search.select();
  }
  if (command && event.key.toLowerCase() === 's' && detailController.getTab() === 'preview') {
    const module = state?.modules.find(item => item.id === selectedID);
    if (module) { event.preventDefault(); previewController.savePreview(module); }
  }
});
mobileLayout.addEventListener?.('change', syncResponsiveNavigation);
window.addEventListener('pagehide', () => stateEventController.close());
window.addEventListener('beforeunload', event => {
  if (previewController.hasUnsavedChanges) { event.preventDefault(); event.returnValue = ''; }
});
window.addEventListener('pageshow', event => { if (event.persisted) stateEventController.start(); });

apiClient.establishSession()
  .catch(error => showToast(error.message, true))
  .finally(() => loadState(true, true).finally(startStateEvents));

function api(path, options = {}) {
  return apiClient.request(path, options);
}

async function loadState(initial = false, renderCurrentDetail = false) {
  const request = ++stateRequest;
  const revision = stateRevision;
  try {
    const next = await api('/api/state');
    if (request !== stateRequest || revision !== stateRevision) return;
    applyState(next, initial, renderCurrentDetail);
  } catch (error) { showToast(error.message, true); }
}

function applyState(next, initial = false, renderCurrentDetail = false) {
    stateRevision += 1;
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
    syncResponsiveNavigation();
    if (initial || renderCurrentDetail || selectionChanged) {
      sidebarController.render();
      activityController.render();
      renderDetail(false);
    } else {
      patchLiveState(previous, next);
      activityController.render();
    }
    stateEventController.syncActivityPolling?.();
}

function applyActivity(activity) {
  if (!state || !activity) return;
  const previousWorking = Boolean(state.activity?.isWorking);
  state = { ...state, activity };
  activityController.render();
  // When a bulk update finishes, refresh module rows/details once.
  if (previousWorking && !activity.isWorking) {
    loadState(false, true);
  } else {
    stateEventController.syncActivityPolling?.();
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

  detailController.patchLiveDetail(previous, next);
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
  case 'add-module': openEditor(); break;
  case 'update-all': await updateAll(); break;
  case 'show-activity': selectItem('activity'); break;
  case 'show-module': selectItem(source.dataset.id); break;
  case 'show-attention': {
    showFailuresOnly = true;
    ui.search.value = '';
    const first = state.modules.find(item => item.state === 'failed' || item.hasOverrideConflict || item.hasSyncConflict);
    if (mobileLayout.matches || !first) showModuleList(true); else selectItem(first.id);
    sidebarController.render();
    break;
  }
  case 'update-module':
    if (module) {
      try { const result = await api(`/api/modules/${module.id}/update`, { method: 'POST' }); showToast(result.message); await loadState(false, true); }
      catch (error) { showToast(error.message, true); }
    }
    break;
  case 'tab-info': detailController.showTab('info'); break;
  case 'tab-preview': detailController.showTab('preview'); break;
  case 'edit': if (module) openEditor(module); break;
  case 'delete': if (module) await deleteModule(module); break;
  case 'copy': await copyText(source.dataset.value, source); break;
  case 'copy-preview': await copyText(previewController.text, source); break;
  case 'save-preview': if (module) await previewController.savePreview(module); break;
  case 'restore-preview': if (module) await previewController.restorePreview(module); break;
  case 'retry-preview': await previewController.retryPreview(); break;
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
  if (!['combined', 'overview', 'activity'].includes(id) && !state.modules.some(module => module.id === id)) id = fallbackSelection();
  if (!id) { showModuleList(pushHistory); return; }
  const cameFromList = mobileLayout.matches && !ui.body.classList.contains('has-selection');
  selectedID = id; detailController.setTab('info'); ui.body.classList.add('has-selection');
  syncResponsiveNavigation();
  resetHorizontalScroll();
  if (pushHistory) {
    const entry = webState.detailHistoryEntry(location, id, cameFromList);
    history.pushState(entry.state, '', entry.url);
  }
  sidebarController.render(); renderDetail(false);
  if (mobileLayout.matches) {
    const heading = ui.detail.querySelector?.('h1');
    if (heading) { heading.tabIndex = -1; heading.focus?.({ preventScroll: true }); }
  }
}

function syncResponsiveNavigation() {
  const detailVisible = ui.body.classList.contains('has-selection');
  if (ui.sidebar) {
    ui.sidebar.inert = mobileLayout.matches && detailVisible;
    ui.sidebar.setAttribute('aria-hidden', String(mobileLayout.matches && detailVisible));
  }
  if (ui.detailPane) ui.detailPane.inert = mobileLayout.matches && !detailVisible;
}

function initializeHistoryState() {
  const transition = webState.initialHistoryTransition(location, history.state);
  if (!transition) return;
  history.replaceState(transition.replace.state, '', transition.replace.url);
  if (transition.push) history.pushState(transition.push.state, '', transition.push.url);
}

function showModuleList(replaceHistory = false) {
  selectedID = null;
  detailController.setTab('info');
  ui.body.classList.remove('has-selection');
  syncResponsiveNavigation();
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
  try {
    const result = await api('/api/update-all', { method: 'POST' });
    showToast(result.message);
    await loadState(false, false);
    stateEventController.syncActivityPolling?.();
  } catch (error) { showToast(error.message, true); }
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
  try { const result = await api(`/api/modules/${module.id}/arguments`, { method: 'DELETE' }); showToast(result.message); detailController.renderModuleDetail(module, true); }
  catch (error) { showToast(error.message, true); }
}
