(function installSurgeRelayWebEditor(global) {
  function createModuleEditorController(dependencies = {}) {
    const ui = dependencies.ui || {};
    const logic = dependencies.logic || global.SurgeRelayWebLogic;
    const markup = dependencies.markup || global.SurgeRelayWebMarkup;
    const options = dependencies.options || global.SurgeRelayWebOptions || {};
    const scriptHubDefaults = dependencies.scriptHubDefaults || options.scriptHubDefaults || {};
    const advancedGroups = dependencies.advancedGroups || options.advancedGroups || [];
    const documentRef = dependencies.document || global.document;
    const windowRef = dependencies.window || global;
    const setTimeoutImpl = dependencies.setTimeout || global.setTimeout;
    const clearTimeoutImpl = dependencies.clearTimeout || global.clearTimeout || (() => {});
    const mobileLayout = dependencies.mobileLayout || { matches: false };
    let nameLookupTimer = null;
    let nameLookupSequence = 0;
    let autoFilledName = '';
    let manualNameEdited = false;
    let resizeAnimation = null;
    const groupAnimations = new WeakMap();

    if (!logic) throw new Error('web-logic.js must load before web-editor.js');
    if (!markup) throw new Error('web-markup.js must load before web-editor.js');

    function formElements() {
      return ui.moduleForm?.elements || {};
    }

    function installAdvancedOptions() {
      if (ui.advancedOptions) {
        ui.advancedOptions.innerHTML = markup.advancedOptionsMarkup(advancedGroups);
      }
    }

    function setAdvancedExpanded(expanded) {
      ui.advancedMaster?.setAttribute('aria-expanded', String(expanded));
      ui.advancedContent?.setAttribute('aria-hidden', String(!expanded));
      ui.advancedContent?.classList?.toggle('expanded', expanded);
    }

    async function animateAdvancedResize(expanded) {
      const dialog = ui.moduleDialog;
      const beforeHeight = dialog?.open ? dialog.getBoundingClientRect().height : 0;
      resizeAnimation?.cancel();
      resizeAnimation = null;
      if (dialog) dialog.style.height = '';
      if (!dialog?.open || !mobileLayout.matches || windowRef.matchMedia?.('(prefers-reduced-motion: reduce)').matches) {
        setAdvancedExpanded(expanded);
        return;
      }

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
      resizeAnimation = animation;
      try { await animation.finished; } catch (_) {}
      if (resizeAnimation !== animation) return;
      resizeAnimation = null;
      dialog.style.height = '';
    }

    async function animateOptionGroup(group) {
      if (!group) return;
      const content = group.querySelector('.option-content');
      if (!content) return;
      const previous = groupAnimations.get(group);
      const opening = previous ? !previous.opening : !group.open;
      const beforeHeight = content.getBoundingClientRect().height;
      previous?.animation.cancel();
      groupAnimations.delete(group);
      content.style.height = '';
      content.style.opacity = '';
      if (windowRef.matchMedia?.('(prefers-reduced-motion: reduce)').matches) {
        group.open = opening;
        return;
      }
      group.open = true;
      const fullHeight = content.scrollHeight;
      const animation = content.animate(
        [{ height: `${beforeHeight}px`, opacity: previous ? 1 : opening ? 0 : 1 },
          { height: `${opening ? fullHeight : 0}px`, opacity: opening ? 1 : 0 }],
        { duration: 220, easing: 'cubic-bezier(.2,.8,.2,1)' }
      );
      groupAnimations.set(group, { animation, opening });
      try { await animation.finished; } catch (_) {}
      if (groupAnimations.get(group)?.animation !== animation) return;
      groupAnimations.delete(group);
      group.open = opening;
    }

    function updateNativeModuleState() {
      const form = formElements();
      const native = logic.isNativeSurgeSource(form.sourceFormat?.value, form.sourceURL?.value);
      if (ui.nativeNote) ui.nativeNote.hidden = !native;
      if (ui.advancedOptions) ui.advancedOptions.hidden = native;
      return native;
    }

    function collectScriptHubOptions() {
      const form = formElements();
      const collected = { ...scriptHubDefaults };
      Object.keys(collected).forEach(key => {
        const field = form[`option_${key}`];
        if (!field) return;
        collected[key] = typeof collected[key] === 'boolean' ? field.checked : field.value;
      });
      return collected;
    }

    function populateScriptHubOptions(values = scriptHubDefaults) {
      const form = formElements();
      const populated = { ...scriptHubDefaults, ...(values || {}) };
      Object.keys(populated).forEach(key => {
        const field = form[`option_${key}`];
        if (!field) return;
        if (typeof populated[key] === 'boolean') field.checked = populated[key]; else field.value = populated[key] || '';
      });
      advancedGroups.forEach(group => {
        const configured = group.fields.some(field => field.key && populated[field.key] !== scriptHubDefaults[field.key]);
        const element = ui.advancedOptions?.querySelector?.(`[data-option-group="${group.id}"]`);
        if (element) element.open = configured;
      });
    }

    function hasAdvancedValues(values) {
      return Object.keys(scriptHubDefaults).some(key => (values?.[key] ?? scriptHubDefaults[key]) !== scriptHubDefaults[key]);
    }

    function populateOutputFolders(selected = '', folders = []) {
      const select = formElements().outputFolder;
      if (!select) return;
      select.innerHTML = markup.outputFolderOptionsMarkup(folders, selected);
      select.value = selected || '';
    }

    function outputFoldersForStorage(state, storageLocation) {
      const editor = state?.moduleEditor || {};
      if (storageLocation === 'both') return [...new Set([...(editor.localOutputFolders || []), ...(editor.githubOutputFolders || [])])];
      return storageLocation === 'local'
        ? (editor.localOutputFolders || [])
        : (editor.githubOutputFolders || []);
    }

    function refreshOutputFolders(state, selected = null, preservingUnknown = false) {
      const form = formElements();
      const folders = outputFoldersForStorage(state, form.storageLocation?.value || 'gitHub');
      const requested = selected ?? form.outputFolder?.value ?? '';
      const nextSelected = preservingUnknown || folders.includes(requested) ? requested : '';
      populateOutputFolders(nextSelected, folders);
    }

    function updateRefreshPolicy() {
      const form = formElements();
      const custom = form.refreshIntervalMinutes?.value === 'custom';
      const input = form.customRefreshIntervalMinutes;
      if (input) { input.disabled = !custom; input.required = custom; }
      const row = documentRef.querySelector?.('#custom-refresh-row');
      if (row) row.hidden = !custom;
    }

    function populateModuleForm(module = null, context = {}) {
      const form = formElements();
      const isEditing = Boolean(module);
      resetNameLookup(module?.name || '', isEditing);
      if (ui.moduleDialogMessage) {
        ui.moduleDialogMessage.hidden = true;
        ui.moduleDialogMessage.textContent = '';
      }
      if (ui.dialogTitle) ui.dialogTitle.textContent = isEditing ? '编辑模块' : '添加模块';
      if (ui.saveModule) ui.saveModule.textContent = isEditing ? '保存' : '添加';
      if (form.name) form.name.value = module?.name || '';
      if (form.category) form.category.value = module?.category || '';
      if (ui.iconURLPreview) ui.iconURLPreview.dataset.fallbackIconUrl = module && !module.customIconURL ? (module.iconURL || '') : '';
      if (form.iconURL) form.iconURL.value = module?.customIconURL || '';
      updateIconURLPreview();
      if (form.outputFileName) form.outputFileName.value = module?.outputFileName || '';
      if (form.sourceURL) form.sourceURL.value = module?.sourceURL || '';
      if (form.sourceFormat) form.sourceFormat.value = module?.sourceFormat || 'automatic';
      if (form.refreshIntervalMinutes) {
        const minutes = module?.refreshIntervalMinutes;
        const valid = Number.isInteger(minutes) && minutes >= 0 && minutes <= 10080;
        const presets = [0, 5, 15, 60, 360, 1440];
        const unknown = minutes != null && !valid;
        form.refreshIntervalMinutes.innerHTML = '<option value="">继承全局</option>' + presets.map(value => `<option value="${value}">${logic.refreshIntervalTitle(value)}</option>`).join('') + '<option value="custom">自定义分钟</option>' + (unknown ? '<option value="unchanged">保留现有策略（未识别）</option>' : '');
        form.refreshIntervalMinutes.value = unknown ? 'unchanged' : minutes == null ? '' : presets.includes(minutes) ? String(minutes) : 'custom';
        if (form.customRefreshIntervalMinutes) form.customRefreshIntervalMinutes.value = valid && minutes > 0 ? String(minutes) : '60';
        updateRefreshPolicy();
      }

      if (form.storageLocation) {
        form.storageLocation.value = module?.storageTargets?.includes('local') && module?.storageTargets?.includes('gitHub')
          ? 'both' : module?.storageTargets?.[0] || module?.storageLocation
          || context.state?.moduleEditor?.defaultStorageLocation
          || 'gitHub';
      }
      refreshOutputFolders(context.state, module?.outputFolder || '', Boolean(module));
      const includeRow = form.isEnabled?.closest?.('.switch-row');
      if (includeRow) includeRow.hidden = !context.combinedEnabled;
      if (form.isEnabled) form.isEnabled.checked = module?.isEnabled ?? false;
      if (form.publishesStandalone) form.publishesStandalone.checked = module?.publishesStandalone ?? true;
      populateScriptHubOptions(module?.scriptHubOptions || scriptHubDefaults);
      setAdvancedExpanded(Boolean(module?.advancedSummary || hasAdvancedValues(module?.scriptHubOptions)));
      updateNativeModuleState();
      updateOutputPathPreview({ state: context.state, editingID: module?.id || null });
      return {
        editingID: module?.id || null,
        focusTarget: isEditing ? form.name : form.sourceURL
      };
    }

    function collectModuleFields() {
      const form = formElements();
      const interval = form.refreshIntervalMinutes?.value;
      const minutes = Number(interval === 'custom' ? form.customRefreshIntervalMinutes?.value || NaN : interval);
      return {
        ...(form.refreshIntervalMinutes && form.refreshIntervalMinutes.value !== 'unchanged' ? { refreshIntervalMinutes: interval === '' ? null : interval === 'custom' && minutes < 1 ? NaN : minutes } : {}),
        name: form.name?.value || '',
        sourceURL: form.sourceURL?.value || '',
        sourceFormat: form.sourceFormat?.value || 'automatic',
        storageLocation: form.storageLocation?.value || 'gitHub',
        storageTargets: form.storageLocation?.value === 'both' ? ['local', 'gitHub'] : [form.storageLocation?.value || 'gitHub'],
        category: form.category?.value || '',
        iconURL: form.iconURL?.value || '',
        outputFolder: form.outputFolder?.value || '',
        outputFileName: form.outputFileName?.value || '',
        isEnabled: Boolean(form.isEnabled?.checked),
        publishesStandalone: Boolean(form.publishesStandalone?.checked),
        scriptHubOptions: collectScriptHubOptions()
      };
    }

    function updateOutputPathPreview(context = {}) {
      if (!ui.outputPathPreview) return null;
      const form = formElements();
      const path = logic.publishedRelativePathForDraft({
        name: form.name?.value,
        sourceURL: form.sourceURL?.value,
        storageLocation: form.storageLocation?.value || 'gitHub',
        outputFolder: form.outputFolder?.value,
        outputFileName: form.outputFileName?.value
      });
      ui.outputPathPreview.textContent = path;
      const notice = logic.outputPathNotice(path, form.publishesStandalone?.checked, {
        combinedFileName: context.state?.combined?.fileName || 'Surge Relay',
        modules: context.state?.modules || [],
        editingID: context.editingID,
        storageLocation: form.storageLocation?.value || 'gitHub',
        publishToLocal: context.state?.moduleEditor?.publishToLocal,
        publishToGitHub: context.state?.moduleEditor?.publishToGitHub
      });
      if (ui.outputPathNote) {
        ui.outputPathNote.textContent = notice?.message || '';
        ui.outputPathNote.hidden = !notice;
        ui.outputPathNote.classList.toggle('warning', Boolean(notice?.warning));
      }
      return { path, notice };
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
      if (value && !logic.isValidHTTPURL(value)) {
        preview.classList.add('invalid');
        preview.innerHTML = '<span class="symbol" data-symbol="shippingbox"></span>';
        return;
      }
      if (!previewURL) {
        preview.innerHTML = '<span class="symbol" data-symbol="shippingbox"></span>';
        return;
      }
      const image = documentRef.createElement('img');
      image.src = previewURL;
      image.alt = '';
      image.loading = 'lazy';
      image.addEventListener('error', () => {
        preview.classList.add('invalid');
        preview.innerHTML = '<span class="symbol" data-symbol="exclamationmark.triangle"></span>';
      }, { once: true });
      preview.append(image);
    }

    function resetNameLookup(initialName = '', isManual = false) {
      clearTimeoutImpl(nameLookupTimer);
      nameLookupTimer = null;
      nameLookupSequence += 1;
      autoFilledName = String(initialName || '');
      manualNameEdited = Boolean(isManual);
      return { autoFilledName, manualNameEdited };
    }

    function handleNameInput(value) {
      manualNameEdited = String(value || '') !== autoFilledName;
      if (!value) manualNameEdited = false;
      return manualNameEdited;
    }

    function scheduleNameLookup(context = {}) {
      clearTimeoutImpl(nameLookupTimer);
      const api = context.api;
      const updateOutputPathPreview = context.updateOutputPathPreview || (() => {});
      const delay = context.delay ?? 500;
      const form = formElements();
      const sourceURL = String(form.sourceURL?.value || '').trim();
      if (!/^https?:\/\//i.test(sourceURL) || manualNameEdited || typeof api !== 'function') return false;
      const sequence = ++nameLookupSequence;
      nameLookupTimer = setTimeoutImpl(async () => {
        try {
          const payload = await api('/api/source/name', { method: 'POST', json: { url: sourceURL } });
          if (sequence !== nameLookupSequence || String(form.sourceURL?.value || '').trim() !== sourceURL || manualNameEdited) return;
          autoFilledName = payload.name || '';
          if (form.name) form.name.value = autoFilledName;
          updateOutputPathPreview();
        } catch (_) {}
      }, delay);
      return true;
    }

    return {
      installAdvancedOptions,
      setAdvancedExpanded,
      animateAdvancedResize,
      animateOptionGroup,
      updateNativeModuleState,
      collectScriptHubOptions,
      populateScriptHubOptions,
      hasAdvancedValues,
      populateOutputFolders,
      outputFoldersForStorage,
      refreshOutputFolders,
      populateModuleForm,
      updateRefreshPolicy,
      collectModuleFields,
      updateOutputPathPreview,
      updateIconURLPreview,
      resetNameLookup,
      handleNameInput,
      scheduleNameLookup,
      get autoFilledName() {
        return autoFilledName;
      },
      get manualNameEdited() {
        return manualNameEdited;
      }
    };
  }

  global.SurgeRelayWebEditor = {
    createModuleEditorController
  };
})(globalThis);
