(function installSurgeRelayWebDetail(global) {
  function createDetailController(dependencies = {}) {
    const ui = dependencies.ui;
    const markup = dependencies.markup || {};
    const logic = dependencies.logic;
    const previewController = dependencies.previewController;
    const api = dependencies.api;
    const documentRef = dependencies.document || global.document;
    const formatDate = dependencies.formatDate || (() => '');
    const getState = dependencies.getState || (() => null);
    const getSelectedID = dependencies.getSelectedID || (() => null);
    const normalizeSelection = dependencies.normalizeSelection;
    const setTimer = dependencies.setTimeout || global.setTimeout;
    const clearTimer = dependencies.clearTimeout || global.clearTimeout;
    let cooldownTimer = null;

    if (!ui || !logic || !previewController || typeof api !== 'function') {
      throw new Error('web-detail.js requires ui, logic, preview and api dependencies');
    }

    const emptyStateMarkup = markup.emptyStateMarkup || (() => '');
    const combinedDetailMarkup = markup.combinedDetailMarkup || (() => '');
    const moduleDetailMarkup = markup.moduleDetailMarkup || (() => '');
    const argumentsSectionMarkup = markup.argumentsSectionMarkup || (() => '');

    let detailTab = 'info';
    let historyVersion = null;
    let historyEntries = [];
    let historyRequest = 0;
    let argumentRequest = 0;

    function getTab() {
      return detailTab;
    }

    function setTab(tab) {
      if (tab !== 'info' && tab !== 'preview') return;
      detailTab = tab;
    }

    function showTab(tab) {
      setTab(tab);
      renderDetail(false);
      ui.detail.querySelector?.(`#detail-tab-${detailTab}`)?.focus?.({ preventScroll: true });
    }

    function handleTabKeydown(event) {
      if (event.isComposing || event.altKey || event.metaKey || event.ctrlKey || !event.target.closest('[role="tab"]')) return;
      if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault();
      showTab(event.key === 'Home' ? 'info' : event.key === 'End' ? 'preview' : detailTab === 'info' ? 'preview' : 'info');
    }

    function renderDetail(animate = true) {
      if (cooldownTimer != null) clearTimer?.(cooldownTimer);
      cooldownTimer = null;
      const state = getState();
      const selectedID = getSelectedID();
      if (!state || !selectedID) { setDetailHTML(emptyStateMarkup('sidebar.left', '选择一个模块'), animate); return; }
      if (selectedID === 'overview') {
        ui.mobileTitle.textContent = '工作台';
        setDetailHTML(markup.workspaceMarkup?.(state) || '', animate);
        return;
      }
      if (selectedID === 'activity') {
        ui.mobileTitle.textContent = '活动记录';
        renderHistory(animate);
        return;
      }
      if (selectedID === 'combined') {
        if (!state.combined.isEnabled) { normalizeSelection?.(); renderDetail(animate); return; }
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
      previewController.deactivate?.();
      ui.detail.innerHTML = `<div class="detail-stage ${animate ? 'page-enter' : ''}">${content}</div>`;
    }

    function renderHistory(animate = false) {
      const state = getState();
      const version = `${state.workspace?.historyCount || 0}:${state.workspace?.recentHistory?.[0]?.id || ''}`;
      const content = entries => `<header class="workspace-heading"><p class="eyebrow">ACTIVITY</p><h1>活动记录</h1><p>回看每一次更新、缓存回退与发布结果。</p></header><section class="workspace-panel">${markup.historyMarkup?.(entries, { detailed: true }) || ''}</section>`;
      setDetailHTML(content(historyEntries.length ? historyEntries : state.workspace?.recentHistory || []), animate);
      if (historyVersion === version) return;
      historyVersion = version;
      const request = ++historyRequest;
      api('/api/history').then(entries => {
        if (request !== historyRequest || !Array.isArray(entries)) return;
        historyEntries = entries;
        if (getSelectedID() === 'activity') setDetailHTML(content(entries), false);
      }).catch(() => { if (request === historyRequest) historyVersion = null; });
    }

    function renderCombinedDetail(animate = true) {
      const state = getState();
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
      scheduleCooldown(module);
      const state = getState();
      setDetailHTML(moduleDetailMarkup(module, {
        selectedTab: detailTab,
        combined: state.combined,
        activity: state.activity
      }), animate);
      if (detailTab === 'preview') {
        previewController.loadPreview(`/api/modules/${module.id}/preview`, true);
        return;
      }
      loadArguments(module);
    }

    function scheduleCooldown(module) {
      if (cooldownTimer != null) clearTimer?.(cooldownTimer);
      cooldownTimer = null;
      const remaining = logic.serverCooldownRemaining(module);
      if (detailTab !== 'info' || !remaining || !setTimer) return;
      cooldownTimer = setTimer(() => {
        cooldownTimer = null;
        if (detailTab !== 'info' || getSelectedID() !== module.id) return;
        const state = getState();
        const current = state?.modules.find(item => item.id === module.id);
        if (!current) return;
        const heading = ui.detail.querySelector?.('.module-heading');
        if (heading && markup.moduleHeaderMarkup) heading.outerHTML = markup.moduleHeaderMarkup(current, state.activity);
        patchDetailValue('服务器冷却', logic.serverCooldownRemaining(current) > 0 ? `${formatDate(current.serverRetryAfter)} 前不可手动更新` : '无（或已结束）');
        scheduleCooldown(current);
      }, Math.min(remaining + 20, 2147483647));
    }

    async function loadArguments(module) {
      const request = ++argumentRequest;
      try {
        const payload = await api(`/api/modules/${module.id}/arguments`);
        if (request !== argumentRequest || getSelectedID() !== module.id || detailTab !== 'info') return;
        const target = documentRef.querySelector('#arguments-section');
        if (!target) return;
        target.innerHTML = argumentsSectionMarkup(payload);
      } catch (_) {}
    }

    function patchDetailValue(label, value, copyValue = null) {
      const row = [...ui.detail.querySelectorAll('.detail-row')]
        .find(item => item.querySelector('.detail-label span:last-child')?.textContent === label);
      const target = row?.querySelector('.detail-value-text') || row?.querySelector('.detail-value');
      if (target && target.textContent !== value) target.textContent = value;
      const copy = row?.querySelector('.detail-copy');
      if (copy && copyValue != null) copy.dataset.value = copyValue;
    }

    // 只更新“信息”页签中变化了字段值，避免整个详情区重排。
    function patchLiveDetail(previous, next) {
      if (detailTab !== 'info') return;
      const selectedID = getSelectedID();
      if (selectedID === 'overview' || selectedID === 'activity') {
        if (JSON.stringify(previous?.workspace) !== JSON.stringify(next.workspace) || logic.sidebarListSignature(previous) !== logic.sidebarListSignature(next)) renderDetail(false);
        return;
      }
      if (selectedID === 'combined') {
        if (!next.combined.isEnabled) return;
        patchDetailValue('包含来源', `${next.combined.enabledCount} / ${next.combined.sourceCount}`);
        patchDetailValue('最新更新', formatDate(next.combined.lastUpdatedAt, '尚未更新'));
        return;
      }

      const module = next.modules.find(item => item.id === selectedID);
      if (!module) return;
      scheduleCooldown(module);
      const heading = ui.detail.querySelector?.('.module-heading');
      if (heading && markup.moduleHeaderMarkup) heading.outerHTML = markup.moduleHeaderMarkup(module, next.activity);
      const previousModule = previous?.modules.find(item => item.id === selectedID);
      if (logic.metadataRowPresenceChanged(previousModule, module)) {
        renderDetail(false);
        return;
      }
      patchDetailValue('更新状态', logic.moduleStatusTitle(module));
      patchDetailValue('初始来源', module.initialSourceTitle || '自写模块');
      patchDetailValue('来源格式', module.sourceFormatTitle);
      if (next.combined.isEnabled) patchDetailValue('汇总订阅', next.combined.subscriptionURL || '等待发布配置');
      patchDetailValue('创建时间', formatDate(module.createdAt, '—'));
      patchDetailValue('上次更新', formatDate(module.lastUpdatedAt, '从未更新'));
      patchDetailValue('来源检查', formatDate(module.sourceCheckedAt, '尚未检查'));
      patchDetailValue('内容 hash', module.contentHash ? module.contentHash.slice(0, 12) : '尚未生成', module.contentHash);
      patchDetailValue('来源 hash', module.sourceContentHash?.slice(0, 12), module.sourceContentHash);
      patchDetailValue('来源 ETag', module.sourceETag, module.sourceETag);
      patchDetailValue('来源修改时间', module.sourceLastModified);
      patchDetailValue('转换引擎', module.conversionEngineRevision ? module.conversionEngineRevision.slice(0, 12) : '原生 Surge 模块', module.conversionEngineRevision);
      if (previousModule?.contentHash !== module.contentHash) loadArguments(module);
    }

    function historyRecordText(index) {
      if (getSelectedID() !== 'activity' || !Number.isInteger(index) || index < 0) return '';
      const entries = historyEntries.length ? historyEntries : getState()?.workspace?.recentHistory || [];
      return global.SurgeRelayWebFormat.historyRecordText(entries[index]);
    }

    function resetWorkspace() {
      detailTab = 'info'; historyVersion = null; historyEntries = [];
      historyRequest += 1; argumentRequest += 1;
      if (cooldownTimer != null) clearTimer?.(cooldownTimer);
      cooldownTimer = null;
      previewController.deactivate?.();
    }

    return {
      resetWorkspace, historyRecordText,
      getTab,
      setTab,
      showTab,
      handleTabKeydown,
      renderDetail,
      renderModuleDetail,
      patchLiveDetail
    };
  }

  function createPublishingController(dependencies = {}) {
    const { ui, api, markup, openDialog, closeDialog, askConfirmation } = dependencies;
    const getState = dependencies.getState || (() => ({ modules: [] }));
    const refreshState = dependencies.refreshState || (() => Promise.resolve());
    const onVersionRestored = dependencies.onVersionRestored || (() => Promise.resolve());
    const escapeHTML = global.SurgeRelayWebFormat.escapeHTML;
    let selectedIDs = new Set();
    let preview = null;
    let attempt = null;
    let comparison = null;
    let syncModule = null;
    let versionModule = null;
    let versionID = null;
    let versionComparison = null;
    let lastRequest = null;
    let generation = 0;
    let busy = false;

    function render(content) {
      ui.operationContent.innerHTML = content;
      ui.operationContent.querySelector('button:not([disabled]), input')?.focus?.({ preventScroll: true });
    }
    function begin(title) {
      generation += 1; busy = false;
      ui.operationTitle.textContent = title;
      openDialog(ui.operationDialog);
      return generation;
    }
    function close() { generation += 1; busy = false; closeDialog(ui.operationDialog); }
    ui.operationDialog?.addEventListener?.('cancel', event => { event.preventDefault(); close(); });
    ui.operationDialog?.addEventListener?.('click', event => { if (event.target === ui.operationDialog) close(); });

    function openSelected(moduleID = null) {
      begin('选择发布模块'); preview = null; comparison = null;
      selectedIDs = new Set(moduleID ? [moduleID] : []);
      render(markup.publicationSelectionMarkup(getState().modules || [], selectedIDs));
    }
    function updateSelection() {
      selectedIDs = new Set([...ui.operationContent.querySelectorAll('[data-publish-module]:checked')].map(input => input.dataset.publishModule));
      const next = ui.operationContent.querySelector('[data-operation="preview-selected"]');
      if (next) next.disabled = selectedIDs.size === 0;
    }
    function showError(error, mode) {
      const changed = error.status === 412 ? '内容或配置已变化，请重新预览或比较。' : error.status === 409 ? '当前有其他操作正在运行，请稍后重试。' : error.message;
      render(`<p role="alert">${escapeHTML(changed || '操作失败')}</p><div class="operation-buttons"><button class="button" data-operation="${mode === 'sync' ? 'refresh-sync' : 'refresh-preview'}">${mode === 'sync' ? '重新比较' : '重新预览'}</button>${mode === 'sync' ? '' : '<button class="button" data-operation="last-result">查看最新发布结果</button>'}</div>`);
    }
    async function requestPreview(request) {
      if (busy) return;
      lastRequest = request; preview = null; busy = true;
      const epoch = generation;
      render('<p role="status">正在计算发布清单…此步骤不会发布文件。</p>');
      try {
        const result = await api('/api/publish/preview', { method: 'POST', json: request });
        if (generation !== epoch) return;
        preview = result; ui.operationTitle.textContent = '核对发布清单';
        render(markup.publicationPreviewMarkup(result));
      } catch (error) { if (generation === epoch) showError(error, 'publish'); }
      finally { if (generation === epoch) busy = false; }
    }
    function openGitHub() { begin('预览发布到 GitHub'); return requestPreview({ scope: 'githubAll' }); }
    async function showLastResult() {
      begin('上次所选发布结果'); busy = true;
      const epoch = generation;
      render('<p role="status">正在读取发布结果…</p>');
      try {
        const result = await api('/api/publishing');
        if (generation !== epoch) return;
        attempt = result.attempt;
        render(markup.publicationResultMarkup(attempt));
      } catch (error) { if (generation === epoch) render(`<p role="alert">${escapeHTML(error.message)}</p><button class="button" data-operation="last-result">重新读取</button>`); }
      finally { if (generation === epoch) busy = false; }
    }
    async function executePublish() {
      if (busy || !preview?.token) return;
      busy = true; const epoch = generation; const ticket = preview;
      const warnings = (ticket.previews || []).reduce((sum, item) => sum + (item.issues || []).filter(issue => issue.severity === 'warning').length, 0);
      const deletions = (ticket.previews || []).reduce((sum, item) => sum + (item.deletedFiles || []).length, 0);
      try {
        if (!await askConfirmation('确认执行发布？', `将向清单中的目标发布${deletions ? `，并删除 ${deletions} 个文件` : ''}。请确认目标和文件清单无误。${warnings ? `清单还有 ${warnings} 条发布提示，请确认已核对并继续。` : ''}`, warnings ? '继续发布' : '确认发布')) return;
        if (generation !== epoch) return;
        preview = null;
        render('<p role="status">正在发布…完成后会显示每个目标的结果。</p>');
        const result = await api('/api/publish', { method: 'POST', json: { token: ticket.token } });
        if (generation === epoch) {
          attempt = result.attempt || null;
          ui.operationTitle.textContent = '发布结果';
          render(markup.publicationResultMarkup(attempt, result.message));
        }
        if (generation === epoch) await refreshState();
      } catch (error) { if (generation === epoch) { preview = null; showError(error, 'publish'); } }
      finally { if (generation === epoch) busy = false; }
    }
    async function refreshSync() {
      if (busy || !syncModule) return;
      busy = true; comparison = null; const epoch = generation;
      render('<p role="status">正在读取并比较本地与 GitHub 内容…</p>');
      try {
        const result = await api(`/api/modules/${syncModule.id}/sync-conflict`);
        if (generation !== epoch) return;
        comparison = result;
        render(markup.synchronizationMarkup(result));
      } catch (error) { if (generation === epoch) showError(error, 'sync'); }
      finally { if (generation === epoch) busy = false; }
    }
    function openSync(module) { begin(`比较两端：${module.name}`); syncModule = module; return refreshSync(); }
    async function resolveSync(direction) {
      if (busy || !comparison?.token || !syncModule) return;
      busy = true; const epoch = generation; const token = comparison.token; const moduleID = syncModule.id;
      const label = direction === 'localToGitHub' ? '用本地覆盖 GitHub' : '用 GitHub 覆盖本地';
      try {
        if (!await askConfirmation(`${label}？`, '目标端的当前正文将被替换。只有两端版本仍与刚才的比较一致时才执行。', label)) return;
        if (generation !== epoch) return;
        comparison = null;
        render('<p role="status">正在按确认的方向同步…</p>');
        const result = await api(`/api/modules/${moduleID}/sync-conflict`, { method: 'POST', json: { token, direction } });
        if (generation === epoch) render(`<p role="status">${escapeHTML(result.message || '同步完成')}</p><button class="button" data-operation="refresh-sync">重新比较两端</button>`);
        if (generation === epoch) await refreshState();
      } catch (error) { if (generation === epoch) { comparison = null; showError(error, 'sync'); } }
      finally { if (generation === epoch) busy = false; }
    }
    function showVersionError(error) {
      const message = error.status === 412 ? '当前缓存或历史版本已变化，请重新比较后再确认恢复。' : error.status === 409 ? '当前有其他操作正在运行，请稍后重新比较。' : error.message;
      render(`<p role="alert">${escapeHTML(message || '版本操作失败')}</p><div class="operation-buttons"><button class="button" data-operation="version-list">返回历史列表</button>${versionID ? '<button class="button" data-operation="refresh-version">重新比较</button>' : ''}</div>`);
    }
    async function loadVersions() {
      if (busy || !versionModule) return;
      busy = true; versionID = null; versionComparison = null;
      const epoch = generation;
      render('<p role="status">正在读取版本历史…</p>');
      try {
        const versions = await api(`/api/modules/${versionModule.id}/versions`);
        if (generation === epoch) render(markup.versionHistoryMarkup(versions));
      } catch (error) { if (generation === epoch) showVersionError(error); }
      finally { if (generation === epoch) busy = false; }
    }
    function openVersions(module) { begin(`版本历史：${module.name}`); versionModule = module; return loadVersions(); }
    async function compareVersion(id) {
      if (busy || !versionModule || !id) return;
      busy = true; versionID = id; versionComparison = null;
      const epoch = generation;
      render('<p role="status">正在比较历史版本与当前缓存…</p>');
      try {
        const result = await api(`/api/modules/${versionModule.id}/versions/${id}`);
        if (generation !== epoch) return;
        versionComparison = result;
        render(markup.versionComparisonMarkup(result));
      } catch (error) { if (generation === epoch) showVersionError(error); }
      finally { if (generation === epoch) busy = false; }
    }
    async function restoreVersion() {
      if (busy || !versionComparison?.token || !versionModule || !versionID) return;
      busy = true;
      const epoch = generation, token = versionComparison.token, moduleID = versionModule.id, selectedVersionID = versionID;
      try {
        if (!await askConfirmation('恢复到缓存并暂停自动刷新？', '将替换当前模块缓存与关联脚本资源。本次仅恢复缓存并暂停该模块自动刷新，不立即发布；后续发布仍按现有发布设置执行。未保存的浏览器草稿会保留；之后可另点“发布此模块”。', '恢复并暂停自动刷新')) return;
        if (generation !== epoch) return;
        versionComparison = null;
        render('<p role="status">正在恢复缓存与脚本资源…不会执行发布。</p>');
        const result = await api(`/api/modules/${moduleID}/versions/${selectedVersionID}/restore`, { method: 'POST', json: { token } });
        if (generation !== epoch) return;
        await onVersionRestored(moduleID);
        if (generation === epoch) render(`<p role="status">${escapeHTML(result.message || '历史版本已恢复到缓存')}。该模块已设为仅手动刷新，本次缓存已恢复且未立即发布；后续发布仍按现有发布设置执行。未保存的浏览器草稿仍保留。</p><p>关闭此窗口后，可另点“发布此模块”预览并确认发布。</p><button class="button" data-operation="version-list">查看版本历史</button>`);
        if (generation === epoch) await refreshState();
      } catch (error) { if (generation === epoch) { versionComparison = null; showVersionError(error); } }
      finally { if (generation === epoch) busy = false; }
    }
    async function handleClick(event) {
      const source = event.target.closest('[data-operation]');
      const action = source?.dataset.operation;
      if (!action || busy) return;
      switch (action) {
      case 'version-list': await loadVersions(); break;
      case 'compare-version': await compareVersion(source.dataset.versionId); break;
      case 'refresh-version': await compareVersion(versionID); break;
      case 'restore-version': await restoreVersion(); break;
      case 'select-all': selectedIDs = new Set((getState().modules || []).filter(module => module.publishesStandalone).map(module => module.id)); render(markup.publicationSelectionMarkup(getState().modules || [], selectedIDs)); break;
      case 'select-none': selectedIDs.clear(); render(markup.publicationSelectionMarkup(getState().modules || [], selectedIDs)); break;
      case 'choose-modules': openSelected(); break;
      case 'preview-selected': if (selectedIDs.size) await requestPreview({ moduleIDs: [...selectedIDs] }); break;
      case 'refresh-preview': if (lastRequest) await requestPreview(lastRequest); else openSelected(); break;
      case 'execute-publish': await executePublish(); break;
      case 'retry-publish': if (attempt?.id) await requestPreview({ retryAttemptID: attempt.id }); break;
      case 'last-result': await showLastResult(); break;
      case 'refresh-sync': await refreshSync(); break;
      case 'local-to-github': await resolveSync('localToGitHub'); break;
      case 'github-to-local': await resolveSync('gitHubToLocal'); break;
      }
    }
    function resetWorkspace() {
      generation += 1; busy = false;
      selectedIDs.clear(); preview = null; attempt = null; comparison = null;
      syncModule = null; versionModule = null; versionID = null; versionComparison = null; lastRequest = null;
      ui.operationDialog?.close?.();
      ui.operationContent.innerHTML = '';
    }
    return { resetWorkspace, openSelected, openGitHub, openSync, openVersions, showLastResult, handleClick, updateSelection, close };
  }

  global.SurgeRelayWebDetail = {
    createDetailController, createPublishingController
  };
})(globalThis);
