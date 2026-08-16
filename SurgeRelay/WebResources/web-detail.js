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
        if (getSelectedID() !== module.id || detailTab !== 'info') return;
        const target = documentRef.querySelector('#arguments-section');
        if (!target || !payload.arguments.length) return;
        target.innerHTML = argumentsSectionMarkup(payload);
      } catch (_) {}
    }

    function patchDetailValue(label, value) {
      const row = [...ui.detail.querySelectorAll('.detail-row')]
        .find(item => item.querySelector('.detail-label span:last-child')?.textContent === label);
      const target = row?.querySelector('.detail-value');
      if (target && target.textContent !== value) target.textContent = value;
    }

    // 只更新“信息”页签中变化了字段值，避免整个详情区重排。
    function patchLiveDetail(previous, next) {
      if (detailTab !== 'info') return;
      const selectedID = getSelectedID();
      if (selectedID === 'combined') {
        if (!next.combined.isEnabled) return;
        patchDetailValue('包含来源', `${next.combined.enabledCount} / ${next.combined.sourceCount}`);
        patchDetailValue('最新更新', formatDate(next.combined.lastUpdatedAt, '尚未更新'));
        return;
      }

      const module = next.modules.find(item => item.id === selectedID);
      if (!module) return;
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
      patchDetailValue('内容 hash', module.contentHash ? module.contentHash.slice(0, 12) : '尚未生成');
      patchDetailValue('转换引擎', module.conversionEngineRevision ? module.conversionEngineRevision.slice(0, 12) : '原生 Surge 模块');
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
