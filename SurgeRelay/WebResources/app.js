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
const { formatDate, formatTime, escapeHTML, escapeAttribute, highlightCode } = webFormat;

const webMarkup = window.SurgeRelayWebMarkup;
if (!webMarkup) throw new Error('web-markup.js must load before app.js');
const {
  detailRow,
  copyableValueSection,
  previewShell,
  latestPublishSection,
  argumentMarkup,
  advancedGroupMarkup
} = webMarkup;

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

let state = null;
let selectedID = null;
let detailTab = 'info';
let editingID = null;
let showFailuresOnly = false;
let previewText = '';
let previewSavedText = '';
let toastTimer = null;
let confirmResolver = null;
let nameLookupTimer = null;
let nameLookupSequence = 0;
let autoFilledName = '';
let manualNameEdited = false;
const mobileLayout = window.matchMedia('(max-width: 700px)');
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

ui.advancedOptions.innerHTML = `<p class="advanced-intro">这些选项由 App 内置的 Script‑Hub 引擎执行，并随当前模块保存。留空即采用上游默认行为。</p>${advancedGroups.map(advancedGroupMarkup).join('')}`;

ui.search.addEventListener('input', renderSidebar);
ui.failureFilter.addEventListener('click', () => {
  showFailuresOnly = !showFailuresOnly;
  renderSidebar();
});
ui.add.addEventListener('click', () => openEditor());
ui.refresh.addEventListener('click', updateAll);
ui.cancelActivity.addEventListener('click', cancelCurrentWork);
ui.summaryRow.addEventListener('click', () => { if (combinedEnabled()) selectItem('combined'); });
ui.back.addEventListener('click', navigateBackToList);
ui.advancedMaster.addEventListener('click', () => animateAdvancedResize(ui.advancedMaster.getAttribute('aria-expanded') !== 'true'));
ui.advancedOptions.addEventListener('click', event => {
  const summary = event.target.closest('.option-group > summary');
  if (!summary) return;
  event.preventDefault();
  animateOptionGroup(summary.parentElement);
});
ui.moduleForm.elements.sourceURL.addEventListener('input', () => {
  updateNativeModuleState();
  updateOutputPathPreview();
  scheduleNameLookup();
});
ui.moduleForm.elements.sourceFormat.addEventListener('change', updateNativeModuleState);
ui.moduleForm.elements.name.addEventListener('input', event => {
  manualNameEdited = event.target.value !== autoFilledName;
  if (!event.target.value) manualNameEdited = false;
  updateOutputPathPreview();
});
ui.moduleForm.elements.outputFolder.addEventListener('change', updateOutputPathPreview);
ui.moduleForm.elements.storageLocation.addEventListener('change', updateOutputPathPreview);
ui.moduleForm.elements.outputFileName.addEventListener('input', updateOutputPathPreview);
ui.moduleForm.elements.iconURL.addEventListener('input', updateIconURLPreview);
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
      renderSidebar();
      renderActivity();
      renderDetail(false);
    } else {
      patchLiveState(previous, next);
      renderActivity();
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
    renderSidebar();
    return;
  }

  const previousList = webLogic.sidebarListSignature(previous);
  const nextList = webLogic.sidebarListSignature(next);
  if (previousList !== nextList) renderSidebar(); else patchSidebarLive();

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

function patchSidebarLive() {
  ui.summaryRow.hidden = !state.combined.isEnabled;
  if (state.combined.isEnabled) ui.summarySubtitle.textContent = `${state.combined.enabledCount} 个来源 · 总模块订阅`;
  state.modules.forEach(module => {
    const row = ui.list.querySelector(`.module-row[data-id="${module.id}"]`);
    if (!row) return;
    row.classList.toggle('disabled', state.combined.isEnabled && !module.isEnabled);
    const toggle = row.querySelector('[data-module-toggle]');
    if (toggle && toggle.checked !== module.isEnabled) toggle.checked = module.isEnabled;
  });
}

function renderSidebar() {
  if (!state) return;
  const query = ui.search.value.trim();
  const filterState = webLogic.sidebarFailureFilterState(state.modules, showFailuresOnly);
  showFailuresOnly = filterState.failuresOnly;
  ui.filterRow.hidden = !filterState.isVisible;
  ui.failureFilter.hidden = !filterState.isVisible;
  ui.failureFilter.setAttribute('aria-pressed', showFailuresOnly ? 'true' : 'false');
  const failureFilterLabel = ui.failureFilter.querySelector('span:last-child');
  if (failureFilterLabel) failureFilterLabel.textContent = filterState.label;
  const modules = webLogic.sidebarModules(state.modules, {
    query,
    failuresOnly: showFailuresOnly
  });
  ui.summaryRow.hidden = !state.combined.isEnabled;
  if (state.combined.isEnabled) ui.summarySubtitle.textContent = `${state.combined.enabledCount} 个来源 · 总模块订阅`;
  ui.summaryRow.classList.toggle('selected', state.combined.isEnabled && selectedID === 'combined');
  const emptyText = webLogic.sidebarEmptyText({ query, failuresOnly: showFailuresOnly });
  ui.list.innerHTML = modules.length ? modules.map(moduleRow).join('') : `<div class="empty-state"><div><span class="symbol" data-symbol="magnifyingglass"></span><div>${emptyText}</div></div></div>`;
}

function moduleRow(module) {
  const icon = module.iconURL ? `<img src="${escapeAttribute(module.iconURL)}" alt="" loading="lazy">` : `<span class="symbol" data-symbol="shippingbox"></span>`;
  const stateClass = `state-${module.state || 'never'}`;
  const stateTitle = webLogic.moduleStatusTitle(module);
  const toggle = state.combined.isEnabled
    ? `<label class="module-toggle" title="${module.isEnabled ? '从总模块中停用' : '包含在总模块中'}"><input type="checkbox" data-module-toggle="${module.id}" ${module.isEnabled ? 'checked' : ''} aria-label="包含 ${escapeAttribute(module.name)}"><span class="toggle-track" aria-hidden="true"></span></label>`
    : '';
  return `<div class="module-row ${selectedID === module.id ? 'selected' : ''} ${state.combined.isEnabled && !module.isEnabled ? 'disabled' : ''}" data-id="${module.id}" role="button" tabindex="0">
    <span class="module-icon ${module.iconURL ? '' : 'placeholder'}">${icon}</span>
    <span class="module-copy"><strong>${escapeHTML(module.name)}</strong><small>${escapeHTML(webLogic.moduleSubtitle(module))}</small></span>
    <span class="module-state-dot ${escapeAttribute(stateClass)}" title="${escapeAttribute(stateTitle)}"></span>
    ${toggle}
  </div>`;
}

function renderActivity() {
  if (!state) return;
  const activity = state.activity;
  const autoPublishText = activity.automaticPublishRunsAt ? ` · 自动发布 ${formatTime(activity.automaticPublishRunsAt)}` : '';
  const canStartUpdate = activity.canStartUpdate !== false;
  const updateBlockedReason = activity.updateBlockedReason || '当前无法开始更新';
  const title = activity.title || '';
  const status = activity.status || (title ? `${title}任务进行中` : '准备就绪');
  const activityText = title && activity.kind !== 'idle' && status !== title
    ? `${title} · ${status}`
    : status;
  ui.status.textContent = `${activityText}${autoPublishText}`;
  ui.refresh.disabled = !canStartUpdate;
  ui.refresh.title = canStartUpdate ? '更新全部' : updateBlockedReason;
  ui.refresh.setAttribute('aria-label', canStartUpdate ? '更新全部' : `无法更新：${updateBlockedReason}`);
  const canCancel = activity.canCancel === true && activity.cancellationRequested !== true && activity.kind !== 'idle';
  ui.cancelActivity.hidden = activity.canCancel !== true || activity.kind === 'idle';
  ui.cancelActivity.disabled = !canCancel;
  ui.cancelActivity.querySelector('span:last-child').textContent = activity.cancellationRequested ? '正在取消' : '取消';
  if (activity.isWorking && activity.progress !== null) {
    const percent = Math.round(activity.progress * 100);
    ui.percent.textContent = `${percent}%`;
    ui.progressTrack.hidden = false;
    ui.progressFill.style.width = `${percent}%`;
  } else {
    ui.percent.textContent = '';
    ui.progressTrack.hidden = true;
    ui.progressFill.style.width = '0%';
  }
  ui.latestUpdate.textContent = formatDate(state.combined.lastUpdatedAt, '尚未更新');
}

function renderDetail(animate = true) {
  if (!state || !selectedID) { setDetailHTML(`<div class="empty-state"><div><span class="symbol" data-symbol="sidebar.left"></span><div>选择一个模块</div></div></div>`, animate); return; }
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

function detailToolbar(module = null) {
  return `<div class="detail-toolbar">
    <div class="segmented-control" aria-label="显示方式">
      <button data-action="tab-info" class="${detailTab === 'info' ? 'selected' : ''}"><span class="symbol" data-symbol="info.circle"></span><span>详情</span></button>
      <button data-action="tab-preview" class="${detailTab === 'preview' ? 'selected' : ''}"><span class="symbol" data-symbol="curlybraces"></span><span>预览</span></button>
    </div>
    ${module ? `<button class="button" data-action="edit"><span class="symbol" data-symbol="pencil"></span>编辑</button><button class="button destructive" data-action="delete"><span class="symbol" data-symbol="trash"></span>删除</button>` : ''}
  </div>`;
}

function renderCombinedDetail(animate = true) {
  const combined = state.combined;
  if (!combined.isEnabled) {
    setDetailHTML(`<div class="empty-state"><div><span class="symbol" data-symbol="square.stack.3d.up"></span><div>总模块功能未开启</div></div></div>`, animate);
    return;
  }
  if (detailTab === 'preview') {
    setDetailHTML(detailToolbar() + previewShell(combined.fileName, false), animate);
    loadPreview('/api/combined/preview', false);
    return;
  }
  const subscription = copyableValueSection('总模块订阅地址', combined.subscriptionURL);
  const latestPublish = latestPublishSection(state.activity?.latestGitHubPublish);
  setDetailHTML(`${detailToolbar()}
    <section class="form-section-view"><h3 class="section-heading">汇总模块</h3><div class="group-box">
      ${detailRow('square.stack.3d.up.fill', '名称', combined.name)}
      ${detailRow('shippingbox', '包含来源', `${combined.enabledCount} / ${combined.sourceCount}`)}
      ${detailRow('clock', '最新更新', formatDate(combined.lastUpdatedAt, '尚未更新'))}
    </div></section>${subscription}${latestPublish}`, animate);
}

function renderModuleDetail(module, animate = true) {
  if (detailTab === 'preview') {
    setDetailHTML(detailToolbar(module) + previewShell(module.publishedRelativePath || module.outputFileName, true), animate);
    loadPreview(`/api/modules/${module.id}/preview`, true);
    return;
  }
  const advanced = module.advancedSummary ? `<section class="form-section-view"><h3 class="section-heading">高级设置</h3><div class="group-box"><div class="detail-row"><div class="detail-label"><span class="symbol" data-symbol="slider.horizontal.3"></span><span>已应用</span></div><div class="detail-value advanced-summary">${escapeHTML(module.advancedSummary)}</div></div></div></section>` : '';
  const publishedTitle = module.publishedURL?.includes('workers.dev') ? 'Cloudflare' : 'GitHub';
  const published = copyableValueSection(publishedTitle, module.publishedURL);
  const errorNote = state.combined.isEnabled ? '如果该来源有缓存，总模块会继续沿用它上一次成功版本。' : '如果该来源有缓存，模块输出会继续沿用它上一次成功版本。';
  const errorBody = module.lastError ? escapeHTML(module.lastError).replace(/\n/g, '<br>') : '';
  const errorActions = module.lastError ? `<div><button class="button" data-action="copy" data-value="${escapeAttribute(module.lastError)}"><span class="symbol" data-symbol="copy"></span>复制错误</button></div>` : '';
  const error = module.lastError ? `<section class="form-section-view"><h3 class="section-heading">最近一次更新失败</h3><div class="group-box"><div class="detail-row action-row error-box"><strong>${escapeHTML(webLogic.moduleStatusTitle(module))}</strong><div>${errorBody}</div><small>${escapeHTML(errorNote)}</small>${errorActions}</div></div></section>` : '';
  const conflict = module.hasOverrideConflict ? `<section class="form-section-view"><h3 class="section-heading">本地编辑冲突</h3><div class="group-box"><div class="detail-row action-row error-box"><strong>上游内容已经变化</strong><div>当前仍在使用本地编辑。可在预览中比较内容后保留或恢复。</div><div><button class="button" data-action="accept-override">保留本地编辑</button><button class="button" data-action="tab-preview">前往预览</button></div></div></div></section>` : '';
  const combinedSubscription = state.combined.subscriptionURL || '';
  const combinedRow = state.combined.isEnabled ? detailRow('square.stack.3d.up.fill', '汇总订阅', combinedSubscription || '等待发布配置', false, combinedSubscription || null) : '';
  const iconURL = module.customIconURL || module.iconURL;
  const iconSource = module.customIconURL ? '自定义图标（仅展示）' : (module.iconURL ? '来源元数据（仅展示）' : '默认图标');
  const iconAddressRow = iconURL ? detailRow('link', '图标地址', `<a href="${escapeAttribute(iconURL)}" target="_blank" rel="noreferrer">${escapeHTML(iconURL)}</a>`, true, iconURL) : '';
  const sourceHashRow = module.sourceContentHash ? detailRow('curlybraces', '来源 hash', module.sourceContentHash.slice(0, 12), false, module.sourceContentHash) : '';
  const sourceETagRow = module.sourceETag ? detailRow('tag', '来源 ETag', module.sourceETag, false, module.sourceETag) : '';
  const sourceLastModifiedRow = module.sourceLastModified ? detailRow('clock', '来源修改时间', module.sourceLastModified) : '';
  const outputPath = module.publishesStandalone ? (module.publishedRelativePath || module.outputFileName) : '';
  const sourceAddress = module.effectiveOriginalSourceURL || module.sourceURL || '';
  const sourceAddressValue = /^https?:\/\//i.test(sourceAddress)
    ? `<a href="${escapeAttribute(sourceAddress)}" target="_blank" rel="noreferrer">${escapeHTML(sourceAddress)}</a>`
    : escapeHTML(sourceAddress);
  const sourceRecordRow = module.sourceURL && module.sourceURL !== sourceAddress
    ? detailRow('link', '来源记录', escapeHTML(module.sourceURL), true, module.sourceURL)
    : '';
  const localStorageRow = module.localStorageRelativePath
    ? detailRow('folder', '本地相对路径', module.localStorageRelativePath, false, module.localStorageRelativePath)
    : '';
  setDetailHTML(`${detailToolbar(module)}
    ${error}
    <section class="form-section-view"><h3 class="section-heading">管理关系</h3><div class="group-box">
      ${detailRow(module.storageLocationIcon || 'folder', '模块存放', module.storageLocationTitle || 'GitHub 模块')}
      ${detailRow(module.sourceOriginIcon || 'link', '转换前来源', module.sourceOriginTitle || module.sourceFormatTitle)}
      ${detailRow('link', '原始地址', sourceAddressValue, true, sourceAddress)}
      ${sourceRecordRow}
      ${detailRow('doc.text', '来源格式', module.sourceFormatTitle)}
      ${detailRow('tag', '模块标签', module.category || '未设置')}
      ${detailRow('folder', '存放文件夹', webLogic.folderTitle(module.outputFolder))}
      ${localStorageRow}
      ${detailRow('doc.on.doc', '输出文件', outputPath || '未开启独立发布', false, outputPath || null)}
      ${detailRow('info.circle', '图标来源', iconSource)}
      ${iconAddressRow}
      ${detailRow('doc.text', '独立模块', module.publishesStandalone ? '发布' : '不发布')}
      ${combinedRow}
      ${detailRow('checkmark', '更新状态', webLogic.moduleStatusTitle(module))}
      ${detailRow('clock', '创建时间', formatDate(module.createdAt, '—'))}
      ${detailRow('clock', '上次更新', formatDate(module.lastUpdatedAt, '从未更新'))}
      ${detailRow('refresh', '来源检查', formatDate(module.sourceCheckedAt, '尚未检查'))}
      ${detailRow('curlybraces', '内容 hash', module.contentHash ? module.contentHash.slice(0, 12) : '尚未生成', false, module.contentHash || null)}
      ${sourceHashRow}
      ${sourceETagRow}
      ${sourceLastModifiedRow}
      ${detailRow('gearshape', '转换引擎', module.conversionEngineRevision ? module.conversionEngineRevision.slice(0, 12) : '原生 Surge 模块', false, module.conversionEngineRevision || null)}
    </div></section>
    ${advanced}<div id="arguments-section"></div>${conflict}${published}`, animate);
  loadArguments(module);
}

async function loadPreview(path, editable) {
  try {
    const text = await api(path);
    if (editable) {
      const editor = document.querySelector('#code-editor');
      if (!editor) return;
      previewText = text; previewSavedText = text; editor.value = text;
      editor.addEventListener('input', () => { previewText = editor.value; const save = document.querySelector('[data-action="save-preview"]'); if (save) save.disabled = previewText === previewSavedText; });
    } else {
      const view = document.querySelector('#code-view');
      if (view) view.innerHTML = highlightCode(text);
      previewText = text; previewSavedText = text;
    }
  } catch (error) { showToast(error.message, true); }
}

async function loadArguments(module) {
  try {
    const payload = await api(`/api/modules/${module.id}/arguments`);
    if (selectedID !== module.id || detailTab !== 'info') return;
    const target = document.querySelector('#arguments-section');
    if (!target || !payload.arguments.length) return;
    target.innerHTML = `<section class="form-section-view page-enter"><h3 class="section-heading">模块参数</h3><div class="group-box">
      ${payload.arguments.map(argumentMarkup).join('')}
      <div class="arguments-footer"><small>修改会立即应用</small><button class="button" data-action="reset-arguments" ${payload.arguments.every(item => item.value === item.defaultValue) ? 'disabled' : ''}>恢复默认值</button></div>
      ${payload.help ? `<details class="parameter-help"><summary><span class="symbol" data-symbol="chevron.right"></span>参数说明</summary><p>${escapeHTML(payload.help)}</p></details>` : ''}
    </div></section>`;
  } catch (_) {}
}

function setAdvancedExpanded(expanded) {
  ui.advancedMaster.setAttribute('aria-expanded', String(expanded));
  ui.advancedContent.setAttribute('aria-hidden', String(!expanded));
  ui.advancedContent.classList.toggle('expanded', expanded);
}

async function animateAdvancedResize(expanded) {
  const dialog = ui.moduleDialog;
  if (!dialog.open || !mobileLayout.matches || window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    setAdvancedExpanded(expanded);
    return;
  }

  const beforeHeight = dialog.getBoundingClientRect().height;
  const previousTransition = ui.advancedContent.style.transition;
  ui.advancedContent.style.transition = 'none';
  setAdvancedExpanded(expanded);
  void ui.advancedContent.offsetHeight;
  const afterHeight = dialog.getBoundingClientRect().height;
  ui.advancedContent.style.transition = previousTransition;

  if (Math.abs(afterHeight - beforeHeight) < 1) return;
  dialog.style.height = `${beforeHeight}px`;
  const animation = dialog.animate(
    [{ height: `${beforeHeight}px` }, { height: `${afterHeight}px` }],
    { duration: 280, easing: 'cubic-bezier(.2,.8,.2,1)' }
  );
  try { await animation.finished; } catch (_) {}
  dialog.style.height = '';
}

async function animateOptionGroup(group) {
  if (!group || group.dataset.animating === 'true') return;
  const content = group.querySelector('.option-content');
  if (!content) return;
  group.dataset.animating = 'true';
  const opening = !group.open;
  if (opening) {
    content.style.height = '0px';
    content.style.opacity = '0';
    group.open = true;
  }
  const fullHeight = content.scrollHeight;
  const animation = content.animate(
    opening
      ? [{ height: '0px', opacity: 0 }, { height: `${fullHeight}px`, opacity: 1 }]
      : [{ height: `${fullHeight}px`, opacity: 1 }, { height: '0px', opacity: 0 }],
    { duration: 220, easing: 'cubic-bezier(.2,.8,.2,1)' }
  );
  try { await animation.finished; } catch (_) {}
  if (!opening) group.open = false;
  content.style.height = '';
  content.style.opacity = '';
  delete group.dataset.animating;
}

function updateNativeModuleState() {
  const form = ui.moduleForm.elements;
  const url = form.sourceURL.value.trim().toLowerCase();
  const native = form.sourceFormat.value === 'surge' || (form.sourceFormat.value === 'automatic' && (url.endsWith('.sgmodule') || url.includes('/surge/')));
  ui.nativeNote.hidden = !native;
  ui.advancedOptions.hidden = native;
}

function scheduleNameLookup() {
  clearTimeout(nameLookupTimer);
  const form = ui.moduleForm.elements;
  const sourceURL = form.sourceURL.value.trim();
  if (!/^https?:\/\//i.test(sourceURL) || manualNameEdited) return;
  const sequence = ++nameLookupSequence;
  nameLookupTimer = setTimeout(async () => {
    try {
      const payload = await api('/api/source/name', { method: 'POST', json: { url: sourceURL } });
      if (sequence !== nameLookupSequence || form.sourceURL.value.trim() !== sourceURL || manualNameEdited) return;
      autoFilledName = payload.name || '';
      form.name.value = autoFilledName;
      updateOutputPathPreview();
    } catch (_) {}
  }, 500);
}

function collectScriptHubOptions() {
  const options = { ...scriptHubDefaults };
  Object.keys(options).forEach(key => {
    const field = ui.moduleForm.elements[`option_${key}`];
    if (!field) return;
    options[key] = typeof options[key] === 'boolean' ? field.checked : field.value;
  });
  return options;
}

function populateScriptHubOptions(values = scriptHubDefaults) {
  const options = { ...scriptHubDefaults, ...(values || {}) };
  Object.keys(options).forEach(key => {
    const field = ui.moduleForm.elements[`option_${key}`];
    if (!field) return;
    if (typeof options[key] === 'boolean') field.checked = options[key]; else field.value = options[key] || '';
  });
  advancedGroups.forEach(group => {
    const configured = group.fields.some(field => field.key && options[field.key] !== scriptHubDefaults[field.key]);
    const element = ui.advancedOptions.querySelector(`[data-option-group="${group.id}"]`);
    if (element) element.open = configured;
  });
}

function hasAdvancedValues(values) { return Object.keys(scriptHubDefaults).some(key => (values?.[key] ?? scriptHubDefaults[key]) !== scriptHubDefaults[key]); }

function populateOutputFolders(selected = '') {
  const select = ui.moduleForm.elements.outputFolder;
  if (!select) return;
  const folders = new Set(['', ...(state?.moduleOutputFolders || []), selected || '']);
  select.innerHTML = [...folders].sort((a, b) => {
    if (!a) return -1;
    if (!b) return 1;
    return a.localeCompare(b, 'zh-Hans-CN', { numeric: true });
  }).map(folder => `<option value="${escapeAttribute(folder)}">${escapeHTML(webLogic.folderTitle(folder))}</option>`).join('');
  select.value = selected || '';
}

function updateOutputPathPreview() {
  if (!ui.outputPathPreview) return;
  const form = ui.moduleForm.elements;
  const path = webLogic.publishedRelativePathForDraft({
    name: form.name.value,
    sourceURL: form.sourceURL.value,
    storageLocation: form.storageLocation?.value || 'gitHub',
    outputFolder: form.outputFolder.value,
    outputFileName: form.outputFileName.value
  });
  ui.outputPathPreview.textContent = path;
  const note = webLogic.outputPathNotice(path, form.publishesStandalone.checked, {
    combinedFileName: state?.combined?.fileName || 'Surge Relay',
    modules: state?.modules || [],
    editingID
  });
  if (ui.outputPathNote) {
    ui.outputPathNote.textContent = note?.message || '';
    ui.outputPathNote.hidden = !note;
    ui.outputPathNote.classList.toggle('warning', Boolean(note?.warning));
  }
}

function updateIconURLPreview() {
  const preview = ui.iconURLPreview;
  const input = ui.moduleForm?.elements?.iconURL;
  if (!preview || !input) return;
  const value = input.value.trim();
  const fallbackURL = preview.dataset.fallbackIconUrl || '';
  const previewURL = value || fallbackURL;
  preview.innerHTML = '';
  preview.classList.toggle('placeholder', !previewURL);
  preview.classList.remove('invalid');
  preview.title = value || (fallbackURL ? '来源图标' : '默认图标');
  if (value && !isValidHTTPURL(value)) {
    preview.classList.add('invalid');
    preview.innerHTML = '<span class="symbol" data-symbol="shippingbox"></span>';
    return;
  }
  if (!previewURL) {
    preview.innerHTML = '<span class="symbol" data-symbol="shippingbox"></span>';
    return;
  }
  const image = document.createElement('img');
  image.src = previewURL;
  image.alt = '';
  image.loading = 'lazy';
  image.addEventListener('error', () => {
    preview.classList.add('invalid');
    preview.innerHTML = '<span class="symbol" data-symbol="exclamationmark.triangle"></span>';
  }, { once: true });
  preview.append(image);
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
  case 'copy-preview': await copyText(previewText, source); break;
  case 'save-preview': if (module) await savePreview(module); break;
  case 'restore-preview': if (module) await restorePreview(module); break;
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
    history.pushState({ surgeRelay: true, view: 'detail', module: id, cameFromList }, '', webState.urlWithModule(location, id));
  }
  renderSidebar(); renderDetail(false);
}

function initializeHistoryState() {
  const module = webState.moduleIDFromLocation(location);
  if (history.state?.surgeRelay) return;
  if (module) {
    history.replaceState({ surgeRelay: true, view: 'list', module: null }, '', webState.urlWithoutModule(location));
    history.pushState({ surgeRelay: true, view: 'detail', module, cameFromList: true }, '', webState.urlWithModule(location, module));
  } else {
    history.replaceState({ surgeRelay: true, view: 'list', module: null }, '', location.href);
  }
}

function showModuleList(replaceHistory = false) {
  selectedID = null;
  detailTab = 'info';
  ui.body.classList.remove('has-selection');
  resetHorizontalScroll();
  if (replaceHistory) history.replaceState({ surgeRelay: true, view: 'list', module: null }, '', webState.urlWithoutModule(location));
  renderSidebar();
  renderDetail(false);
}

function navigateBackToList() {
  if (!mobileLayout.matches) return;
  if (history.state?.surgeRelay && history.state?.cameFromList) history.back();
  else showModuleList(true);
}

function handleHistoryNavigation(event) {
  const module = webState.moduleIDFromLocation(location);
  if (mobileLayout.matches && (!module || event.state?.view === 'list')) {
    showModuleList(false);
    return;
  }
  selectItem(module || fallbackSelection(), false);
}

function openEditor(module = null) {
  clearTimeout(nameLookupTimer);
  nameLookupSequence += 1;
  editingID = module?.id || null;
  ui.moduleDialogMessage.hidden = true;
  ui.moduleDialogMessage.textContent = '';
  ui.dialogTitle.textContent = module ? '编辑模块' : '添加模块';
  ui.saveModule.textContent = module ? '保存' : '添加';
  const form = ui.moduleForm.elements;
  form.name.value = module?.name || '';
  form.category.value = module?.category || '';
  ui.iconURLPreview.dataset.fallbackIconUrl = module && !module.customIconURL ? (module.iconURL || '') : '';
  form.iconURL.value = module?.customIconURL || '';
  updateIconURLPreview();
  populateOutputFolders(module?.outputFolder || '');
  form.outputFileName.value = module?.outputFileName || '';
  autoFilledName = module?.name || '';
  manualNameEdited = Boolean(module);
  form.sourceURL.value = module?.sourceURL || '';
  form.sourceFormat.value = module?.sourceFormat || 'automatic';
  form.storageLocation.value = module?.storageLocation || 'gitHub';
  const includeRow = form.isEnabled?.closest('.switch-row');
  if (includeRow) includeRow.hidden = !combinedEnabled();
  form.isEnabled.checked = module?.isEnabled ?? false;
  form.publishesStandalone.checked = module?.publishesStandalone ?? true;
  populateScriptHubOptions(module?.scriptHubOptions || scriptHubDefaults);
  setAdvancedExpanded(Boolean(module?.advancedSummary || hasAdvancedValues(module?.scriptHubOptions)));
  updateNativeModuleState();
  updateOutputPathPreview();
  openDialog(ui.moduleDialog);
  const formContent = ui.moduleDialog.querySelector('.form-content');
  if (formContent) formContent.scrollTop = 0;
  setTimeout(() => (module ? form.name : form.sourceURL).focus(), 180);
}

async function saveModule(event) {
  event.preventDefault();
  const form = ui.moduleForm.elements;
  const existingModule = editingID ? state.modules.find(module => module.id === editingID) : null;
  const iconURL = form.iconURL.value.trim();
  if (iconURL && !isValidHTTPURL(iconURL)) {
    ui.moduleDialogMessage.textContent = '图标 URL 仅支持完整的 HTTP 或 HTTPS 地址。';
    ui.moduleDialogMessage.hidden = false;
    form.iconURL.focus();
    return;
  }
  const payload = {
    name: form.name.value.trim(),
    sourceURL: form.sourceURL.value.trim(),
    sourceFormat: form.sourceFormat.value,
    storageLocation: form.storageLocation.value,
    category: form.category.value.trim(),
    iconURL,
    outputFolder: form.outputFolder.value,
    outputFileName: form.outputFileName.value.trim(),
    isEnabled: combinedEnabled() ? form.isEnabled.checked : (existingModule?.isEnabled ?? false),
    publishesStandalone: form.publishesStandalone.checked,
    scriptHubOptions: collectScriptHubOptions()
  };
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

function isValidHTTPURL(value) {
  try {
    const url = new URL(value);
    return (url.protocol === 'http:' || url.protocol === 'https:') && Boolean(url.hostname);
  } catch {
    return false;
  }
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

async function savePreview(module) {
  try { const result = await api(`/api/modules/${module.id}/preview`, { method: 'PUT', headers: { 'Content-Type': 'text/plain; charset=utf-8' }, body: previewText }); previewSavedText = previewText; document.querySelector('[data-action="save-preview"]').disabled = true; showToast(result.message); }
  catch (error) { showToast(error.message, true); }
}

async function restorePreview(module) {
  if (!await askConfirmation('恢复转换结果？', `“${module.name}”的手动修改会被丢弃。`, '恢复')) return;
  try { const text = await api(`/api/modules/${module.id}/preview`, { method: 'DELETE' }); const editor = document.querySelector('#code-editor'); if (editor) editor.value = text; previewText = text; previewSavedText = text; document.querySelector('[data-action="save-preview"]').disabled = true; showToast('已恢复转换结果'); }
  catch (error) { showToast(error.message, true); }
}

async function resetArguments(module) {
  try { const result = await api(`/api/modules/${module.id}/arguments`, { method: 'DELETE' }); showToast(result.message); renderModuleDetail(module, true); }
  catch (error) { showToast(error.message, true); }
}

function openDialog(dialog) { dialog.classList.remove('is-closing'); dialog.showModal(); }
function closeDialog(dialog) { return new Promise(resolve => { if (!dialog.open) return resolve(); dialog.classList.add('is-closing'); setTimeout(() => { dialog.close(); dialog.classList.remove('is-closing'); resolve(); }, 165); }); }
function askConfirmation(title, message, acceptLabel = '确认') { ui.confirmTitle.textContent = title; ui.confirmMessage.textContent = message; ui.confirmAccept.textContent = acceptLabel; openDialog(ui.confirmDialog); return new Promise(resolve => { confirmResolver = resolve; }); }
async function resolveConfirmation(value) { const resolver = confirmResolver; confirmResolver = null; await closeDialog(ui.confirmDialog); resolver?.(value); }

function resetHorizontalScroll() {
  document.documentElement.scrollLeft = 0;
  document.body.scrollLeft = 0;
  window.scrollTo(0, window.scrollY);
}

async function copyText(text, button = null) {
  try {
    if (navigator.clipboard?.writeText) await navigator.clipboard.writeText(text || '');
    else {
      const textarea = document.createElement('textarea');
      textarea.value = text || '';
      document.body.append(textarea);
      textarea.select();
      document.execCommand('copy');
      textarea.remove();
    }
    showCopySuccess(button);
  } catch (_) {
    showToast('拷贝失败', true);
  }
}

function showCopySuccess(button) {
  if (!button) return;
  if (!button.dataset.copyLabel) button.dataset.copyLabel = button.innerHTML;
  clearTimeout(Number(button.dataset.copyTimer || 0));
  button.innerHTML = '<span class="symbol" data-symbol="checkmark"></span>拷贝成功';
  button.classList.add('copy-success');
  const timer = setTimeout(() => {
    if (!button.isConnected) return;
    button.innerHTML = button.dataset.copyLabel;
    button.classList.remove('copy-success');
    delete button.dataset.copyLabel;
    delete button.dataset.copyTimer;
  }, 1600);
  button.dataset.copyTimer = String(timer);
}

function showToast(message, isError = false) { clearTimeout(toastTimer); ui.toast.textContent = message; ui.toast.classList.toggle('error', isError); ui.toast.classList.add('visible'); toastTimer = setTimeout(() => ui.toast.classList.remove('visible'), 2600); }
