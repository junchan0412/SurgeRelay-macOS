(function installSurgeRelayWebSidebar(global) {
  const logic = global.SurgeRelayWebLogic;
  if (!logic) throw new Error('web-logic.js must load before web-sidebar.js');
  const markup = global.SurgeRelayWebMarkup;
  if (!markup) throw new Error('web-markup.js must load before web-sidebar.js');

  function createSidebarController(options = {}) {
    const { ui } = options;
    const getState = options.getState || (() => null);
    const getSelectedID = options.getSelectedID || (() => null);
    const getFailuresOnly = options.getFailuresOnly || (() => false);
    const setFailuresOnly = options.setFailuresOnly || (() => {});

    function render() {
      const state = getState();
      if (!state) return;
      const query = ui.search.value.trim();
      const filterState = logic.sidebarFailureFilterState(state.modules, getFailuresOnly());
      setFailuresOnly(filterState.failuresOnly);
      ui.filterRow.hidden = !filterState.isVisible;
      ui.failureFilter.hidden = !filterState.isVisible;
      ui.failureFilter.setAttribute('aria-pressed', filterState.failuresOnly ? 'true' : 'false');
      const failureFilterLabel = ui.failureFilter.querySelector('span:last-child');
      if (failureFilterLabel) failureFilterLabel.textContent = filterState.label;
      const modules = logic.sidebarModules(state.modules, {
        query,
        failuresOnly: filterState.failuresOnly
      });
      ui.summaryRow.hidden = !state.combined.isEnabled;
      if (state.combined.isEnabled) {
        ui.summarySubtitle.textContent = `${state.combined.enabledCount} 个来源 · 总模块订阅`;
      }
      const selectedID = getSelectedID();
      ui.summaryRow.classList.toggle('selected', state.combined.isEnabled && selectedID === 'combined');
      const emptyText = logic.sidebarEmptyText({ query, failuresOnly: filterState.failuresOnly });
      ui.list.innerHTML = modules.length
        ? modules.map(module => markup.moduleRowMarkup(module, {
          selectedID,
          combinedEnabled: state.combined.isEnabled
        })).join('')
        : markup.emptyStateMarkup('magnifyingglass', emptyText);
    }

    function patchLive() {
      const state = getState();
      if (!state) return;
      ui.summaryRow.hidden = !state.combined.isEnabled;
      if (state.combined.isEnabled) {
        ui.summarySubtitle.textContent = `${state.combined.enabledCount} 个来源 · 总模块订阅`;
      }
      state.modules.forEach(module => {
        const row = ui.list.querySelector(`.module-row[data-id="${module.id}"]`);
        if (!row) return;
        row.classList.toggle('disabled', state.combined.isEnabled && !module.isEnabled);
        const toggle = row.querySelector('[data-module-toggle]');
        if (toggle && toggle.checked !== module.isEnabled) toggle.checked = module.isEnabled;
      });
    }

    function toggleFailuresOnly() {
      setFailuresOnly(!getFailuresOnly());
      render();
    }

    return {
      render,
      patchLive,
      toggleFailuresOnly
    };
  }

  global.SurgeRelayWebSidebar = {
    createSidebarController
  };
})(this);
