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
    const mobileLayout = dependencies.mobileLayout || { matches: false };

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
      if (!dialog?.open || !mobileLayout.matches || windowRef.matchMedia?.('(prefers-reduced-motion: reduce)').matches) {
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
        editingID: context.editingID
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
      updateOutputPathPreview,
      updateIconURLPreview
    };
  }

  global.SurgeRelayWebEditor = {
    createModuleEditorController
  };
})(globalThis);
