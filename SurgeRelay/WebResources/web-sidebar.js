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
    const documentRef = options.document || global.document;
    const selectItem = options.selectItem || (() => {});
    let visibleIDs = [];
    let renderedRows = new Map();
    let rowElements = new Map();
    let previousSelection = null;

    function render() {
      const state = getState();
      if (!state) return;
      const query = ui.search.value.trim();
      if (ui.clearSearch) ui.clearSearch.hidden = !ui.search.value;
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
      const count = documentRef?.querySelector?.('#module-count');
      const resultCount = query || filterState.failuresOnly ? `${modules.length} / ${state.modules.length}` : String(modules.length);
      if (count) count.textContent = resultCount;
      if (ui.searchStatus) {
        const message = query || filterState.failuresOnly ? `找到 ${modules.length} 个模块，共 ${state.modules.length} 个` : '';
        if (ui.searchStatus.textContent !== message) ui.searchStatus.textContent = message;
      }
      for (const [element, id] of [[ui.overview, 'overview'], [ui.history, 'activity']]) {
        element?.classList.toggle('selected', selectedID === id);
        element?.setAttribute('aria-current', selectedID === id ? 'page' : 'false');
      }
      ui.summaryRow.classList.toggle('selected', state.combined.isEnabled && selectedID === 'combined');
      ui.summaryRow.setAttribute?.('aria-current', selectedID === 'combined' ? 'page' : 'false');
      const emptyText = logic.sidebarEmptyText({ query, failuresOnly: filterState.failuresOnly });
      const nextIDs = modules.map(module => module.id);
      const focused = documentRef?.activeElement;
      const focusedRow = focused?.closest?.('.module-row');
      const focusedID = focusedRow?.dataset.id;
      const context = { combinedEnabled: state.combined.isEnabled };
      const nextRows = new Map(modules.map(module => [module.id, markup.moduleRowMarkup(module, context)]));
      let rebuild = !nextIDs.length || nextIDs.length !== visibleIDs.length || nextIDs.some((id, index) => id !== visibleIDs[index]);
      if (!rebuild) {
        for (const module of modules) {
          if (nextRows.get(module.id) === renderedRows.get(module.id)) continue;
          const row = rowElements.get(module.id);
          if (!row) { rebuild = true; break; }
          row.outerHTML = markup.moduleRowMarkup(module, { ...context, selectedID });
          rowElements.set(module.id, ui.list.querySelector(`.module-row[data-id="${module.id}"]`));
        }
      }
      if (rebuild) {
        const html = modules.length
          ? modules.map(module => markup.moduleRowMarkup(module, { ...context, selectedID })).join('')
          : markup.emptyStateMarkup('magnifyingglass', emptyText);
        if (ui.list.innerHTML !== html) ui.list.innerHTML = html;
        rowElements = new Map([...ui.list.querySelectorAll('.module-row')].map(row => [row.dataset.id, row]));
      }
      for (const id of new Set([previousSelection, selectedID])) {
        const row = rowElements.get(id);
        row?.classList.toggle('selected', id === selectedID);
        row?.querySelector('.module-open')?.setAttribute('aria-current', id === selectedID ? 'page' : 'false');
      }
      if (focusedID && documentRef.activeElement !== focused) {
        const replacement = rowElements.get(focusedID);
        const target = focused?.matches?.('[data-module-toggle]') ? '[data-module-toggle]' : '.module-open';
        (replacement?.querySelector(target) || ui.search).focus?.({ preventScroll: true });
      }
      visibleIDs = nextIDs;
      renderedRows = nextRows;
      previousSelection = selectedID;
    }

    function patchLive() {
      const state = getState();
      if (!state) return;
      ui.summaryRow.hidden = !state.combined.isEnabled;
      if (state.combined.isEnabled) {
        ui.summarySubtitle.textContent = `${state.combined.enabledCount} 个来源 · 总模块订阅`;
      }
      state.modules.forEach(module => {
        const row = rowElements.get(module.id) || ui.list.querySelector(`.module-row[data-id="${module.id}"]`);
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

    function clearSearch() {
      ui.search.value = '';
      render();
      ui.search.focus();
    }

    function focusRow(index) {
      const row = rowElements.get(visibleIDs[index]);
      const button = row?.querySelector('.module-open');
      button?.focus({ preventScroll: true });
      row?.scrollIntoView?.({ block: 'nearest' });
    }

    function handleSearchKeydown(event) {
      if (event.isComposing || event.altKey || event.metaKey || event.ctrlKey) return;
      if (event.key === 'Escape' && ui.search.value) { event.preventDefault(); clearSearch(); }
      if (!visibleIDs.length) return;
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        focusRow(event.key === 'ArrowDown' ? 0 : visibleIDs.length - 1);
      }
      if (event.key === 'Enter') { event.preventDefault(); selectItem(visibleIDs[0]); }
    }

    function handleListKeydown(event) {
      if (event.isComposing || event.altKey || event.metaKey || event.ctrlKey || event.target.closest('.module-toggle')) return;
      const id = event.target.closest('.module-row')?.dataset.id;
      const index = visibleIDs.indexOf(id);
      if (index < 0) return;
      const target = { ArrowDown: Math.min(index + 1, visibleIDs.length - 1), ArrowUp: Math.max(index - 1, 0), Home: 0, End: visibleIDs.length - 1 }[event.key];
      if (target !== undefined) { event.preventDefault(); focusRow(target); }
      if (event.key === 'Escape') { event.preventDefault(); ui.search.focus(); ui.search.select(); }
    }

    return {
      render,
      patchLive,
      toggleFailuresOnly,
      clearSearch,
      handleSearchKeydown,
      handleListKeydown
    };
  }

  global.SurgeRelayWebSidebar = {
    createSidebarController
  };
})(this);
