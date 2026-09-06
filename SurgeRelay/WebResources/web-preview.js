(function installSurgeRelayWebPreview(global) {
  function createPreviewController(dependencies = {}) {
    const api = dependencies.api;
    const documentRef = dependencies.document || global.document;
    const highlightCode = dependencies.highlightCode || (text => String(text || ''));
    const askConfirmation = dependencies.askConfirmation || (() => Promise.resolve(false));
    const showToast = dependencies.showToast || (() => {});
    const drafts = new Map();
    let previewText = '';
    let previewSavedText = '';
    let activePath = null;
    let requestGeneration = 0;

    if (typeof api !== 'function') throw new Error('web-preview.js requires an api function');

    function updateSaveButton() {
      const save = documentRef.querySelector('[data-action="save-preview"]');
      if (save) save.disabled = previewText === previewSavedText;
    }

    function remember(path, text, savedText) {
      if (text === savedText) drafts.delete(path);
      else drafts.set(path, { text, savedText });
    }

    function mountEditor(editor, path, text, savedText) {
      previewText = text;
      previewSavedText = savedText;
      editor.value = text;
      editor.disabled = false;
      updateSaveButton();
      if (editor.relayPreviewBound) return;
      editor.relayPreviewBound = true;
      editor.addEventListener('input', () => {
        if (activePath !== path) return;
        previewText = editor.value;
        remember(path, previewText, previewSavedText);
        updateSaveButton();
      });
    }

    async function loadPreview(path, editable) {
      const generation = ++requestGeneration;
      activePath = path;
      const editor = editable ? documentRef.querySelector('#code-editor') : null;
      const draft = drafts.get(path);
      if (editable && editor && draft) {
        mountEditor(editor, path, draft.text, draft.savedText);
        return;
      }
      if (editor) editor.disabled = true;
      try {
        const text = await api(path);
        if (generation !== requestGeneration || activePath !== path) return;
        if (editable) {
          const target = documentRef.querySelector('#code-editor');
          if (!target) return;
          mountEditor(target, path, text, text);
        } else {
          const view = documentRef.querySelector('#code-view');
          if (view) view.innerHTML = highlightCode(text);
          previewText = text;
          previewSavedText = text;
        }
      } catch (error) {
        if (generation !== requestGeneration) return;
        if (editor) editor.value = '无法读取模块内容，请重新打开内容页重试。';
        showToast(error.message, true);
      }
    }

    async function savePreview(module) {
      const path = `/api/modules/${module.id}/preview`;
      const submittedText = previewText;
      try {
        const result = await api(path, {
          method: 'PUT', headers: { 'Content-Type': 'text/plain; charset=utf-8' }, body: submittedText
        });
        const currentText = activePath === path ? previewText : drafts.get(path)?.text ?? submittedText;
        remember(path, currentText, submittedText);
        if (activePath === path) { previewSavedText = submittedText; updateSaveButton(); }
        showToast(result.message);
      } catch (error) { showToast(error.message, true); }
    }

    async function restorePreview(module) {
      if (!await askConfirmation('恢复转换结果？', `“${module.name}”的手动修改会被丢弃。`, '恢复')) return;
      const path = `/api/modules/${module.id}/preview`;
      try {
        const text = await api(path, { method: 'DELETE' });
        drafts.delete(path);
        if (activePath === path) {
          const editor = documentRef.querySelector('#code-editor');
          if (editor) mountEditor(editor, path, text, text);
        }
        showToast('已恢复转换结果');
      } catch (error) { showToast(error.message, true); }
    }

    return {
      loadPreview, savePreview, restorePreview,
      get text() { return previewText; },
      get savedText() { return previewSavedText; },
      get hasUnsavedChanges() { return drafts.size > 0; }
    };
  }
  global.SurgeRelayWebPreview = { createPreviewController };
})(globalThis);
