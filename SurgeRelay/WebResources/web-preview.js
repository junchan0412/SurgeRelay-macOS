(function installSurgeRelayWebPreview(global) {
  function createPreviewController(dependencies = {}) {
    const api = dependencies.api;
    const documentRef = dependencies.document || global.document;
    const highlightCode = dependencies.highlightCode || (text => String(text || ''));
    const askConfirmation = dependencies.askConfirmation || (() => Promise.resolve(false));
    const showToast = dependencies.showToast || (() => {});
    let previewText = '';
    let previewSavedText = '';

    if (typeof api !== 'function') {
      throw new Error('web-preview.js requires an api function');
    }

    async function loadPreview(path, editable) {
      try {
        const text = await api(path);
        if (editable) {
          const editor = documentRef.querySelector('#code-editor');
          if (!editor) return;
          previewText = text;
          previewSavedText = text;
          editor.value = text;
          editor.addEventListener('input', () => {
            previewText = editor.value;
            const save = documentRef.querySelector('[data-action="save-preview"]');
            if (save) save.disabled = previewText === previewSavedText;
          });
        } else {
          const view = documentRef.querySelector('#code-view');
          if (view) view.innerHTML = highlightCode(text);
          previewText = text;
          previewSavedText = text;
        }
      } catch (error) {
        showToast(error.message, true);
      }
    }

    async function savePreview(module) {
      try {
        const result = await api(`/api/modules/${module.id}/preview`, {
          method: 'PUT',
          headers: { 'Content-Type': 'text/plain; charset=utf-8' },
          body: previewText
        });
        previewSavedText = previewText;
        const save = documentRef.querySelector('[data-action="save-preview"]');
        if (save) save.disabled = true;
        showToast(result.message);
      } catch (error) {
        showToast(error.message, true);
      }
    }

    async function restorePreview(module) {
      const accepted = await askConfirmation(
        '恢复转换结果？',
        `“${module.name}”的手动修改会被丢弃。`,
        '恢复'
      );
      if (!accepted) return;
      try {
        const text = await api(`/api/modules/${module.id}/preview`, { method: 'DELETE' });
        const editor = documentRef.querySelector('#code-editor');
        if (editor) editor.value = text;
        previewText = text;
        previewSavedText = text;
        const save = documentRef.querySelector('[data-action="save-preview"]');
        if (save) save.disabled = true;
        showToast('已恢复转换结果');
      } catch (error) {
        showToast(error.message, true);
      }
    }

    return {
      loadPreview,
      savePreview,
      restorePreview,
      get text() {
        return previewText;
      },
      get savedText() {
        return previewSavedText;
      }
    };
  }

  global.SurgeRelayWebPreview = {
    createPreviewController
  };
})(globalThis);
