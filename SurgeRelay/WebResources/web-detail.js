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

    function renderDetail(animate = true) {
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

    return {
      getTab,
      setTab,
      renderDetail,
      renderModuleDetail,
      patchLiveDetail
    };
  }

  global.SurgeRelayWebDetail = {
    createDetailController
  };
})(globalThis);
