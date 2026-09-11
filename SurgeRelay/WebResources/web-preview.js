(function installSurgeRelayWebPreview(global) {
  function createPreviewController(dependencies = {}) {
    const api = dependencies.api;
    const documentRef = dependencies.document || global.document;
    const highlightCode = dependencies.highlightCode || (text => String(text || ''));
    const askConfirmation = dependencies.askConfirmation || (() => Promise.resolve(false));
    const showToast = dependencies.showToast || (() => {});
    const drafts = new Map();
    const pendingActions = new Map();
    const viewPositions = new Map();
    let previewText = '';
    let previewSavedText = '';
    let activePath = null;
    let activeEditable = false;
    let loaded = false;
    let loadError = '';
    let plainPreview = false;
    let requestGeneration = 0;

    if (typeof api !== 'function') throw new Error('web-preview.js requires an api function');

    function updateActions() {
      const pending = pendingActions.get(activePath);
      const save = documentRef.querySelector('[data-action="save-preview"]');
      if (save) {
        save.hidden = Boolean(loadError);
        save.disabled = !loaded || Boolean(pending) || previewText === previewSavedText;
        save.textContent = pending === 'save' ? '写入中…' : '写入';
      }
      const restore = documentRef.querySelector('[data-action="restore-preview"]');
      if (restore) { restore.hidden = Boolean(loadError); restore.disabled = !loaded || Boolean(pending); }
      const copy = documentRef.querySelector('[data-action="copy-preview"]');
      if (copy) { copy.hidden = Boolean(loadError); copy.disabled = !loaded; }
      const retry = documentRef.querySelector('[data-action="retry-preview"]');
      if (retry) retry.hidden = !loadError;
      const message = documentRef.querySelector('#preview-message');
      if (message) { message.hidden = !loadError; message.textContent = loadError; }
      const status = documentRef.querySelector('#preview-status');
      if (status) {
        const dirty = activeEditable && previewText !== previewSavedText;
        const state = loadError ? 'error' : !loaded ? 'loading' : pending === 'save' ? 'saving' : pending === 'restore' ? 'restoring' : dirty ? 'dirty' : 'saved';
        const label = { error: '读取失败', loading: '正在载入', saving: '正在写入…', restoring: '正在恢复…', dirty: '未保存', saved: activeEditable ? '已保存' : plainPreview ? '大文件 · 纯文本显示' : '只读预览' }[state];
        if (status.textContent !== label) status.textContent = label;
        status.dataset.state = state;
      }
    }

    function remember(path, text, savedText) {
      if (text === savedText && !pendingActions.has(path)) drafts.delete(path);
      else drafts.set(path, { text, savedText });
    }

    function mountEditor(editor, path, text, savedText) {
      loaded = true;
      previewText = text;
      previewSavedText = savedText;
      editor.value = text;
      editor.disabled = false;
      editor.relayPreviewPath = path;
      const position = viewPositions.get(path);
      if (position) {
        editor.setSelectionRange?.(position.start, position.end);
        editor.scrollTop = position.scrollTop;
        editor.scrollLeft = position.scrollLeft;
      }
      updateActions();
      if (editor.relayPreviewBound) return;
      editor.relayPreviewBound = true;
      editor.addEventListener('input', () => {
        const path = editor.relayPreviewPath;
        if (activePath !== path) return;
        previewText = editor.value;
        remember(path, previewText, previewSavedText);
        updateActions();
      });
    }

    function deactivate() {
      const editor = activeEditable && loaded ? documentRef.querySelector('#code-editor') : null;
      if (editor && activePath) {
        viewPositions.set(activePath, { start: editor.selectionStart, end: editor.selectionEnd, scrollTop: editor.scrollTop, scrollLeft: editor.scrollLeft });
      }
      requestGeneration += 1;
      activePath = null;
      activeEditable = false;
      loaded = false;
    }

    async function loadPreview(path, editable) {
      const generation = ++requestGeneration;
      activePath = path;
      activeEditable = editable;
      loaded = false;
      loadError = '';
      plainPreview = false;
      previewText = '';
      previewSavedText = '';
      const editor = editable ? documentRef.querySelector('#code-editor') : null;
      const draft = drafts.get(path);
      if (editable && editor && draft) {
        mountEditor(editor, path, draft.text, draft.savedText);
        return;
      }
      if (editor) { editor.disabled = true; editor.value = '正在载入…'; }
      updateActions();
      try {
        const text = await api(path);
        if (generation !== requestGeneration || activePath !== path) return;
        if (editable) {
          const target = documentRef.querySelector('#code-editor');
          if (!target) return;
          mountEditor(target, path, text, text);
        } else {
          const view = documentRef.querySelector('#code-view');
          plainPreview = text.length > 256 * 1024;
          if (view) {
            if (plainPreview) view.textContent = text;
            else view.innerHTML = highlightCode(text);
          }
          previewText = text;
          previewSavedText = text;
          loaded = true;
          updateActions();
        }
      } catch (error) {
        if (generation !== requestGeneration) return;
        loadError = `无法读取模块内容。${error.message || '请检查连接后重试。'}`;
        if (editor) editor.value = '';
        const view = documentRef.querySelector('#code-view');
        if (view) view.textContent = '';
        updateActions();
        showToast(error.message, true);
      }
    }

    async function savePreview(module) {
      const path = `/api/modules/${module.id}/preview`;
      if (activePath !== path || !activeEditable || !loaded || pendingActions.has(path) || previewText === previewSavedText) return;
      const submittedText = previewText;
      pendingActions.set(path, 'save');
      remember(path, submittedText, previewSavedText);
      updateActions();
      try {
        const result = await api(path, {
          method: 'PUT', headers: { 'Content-Type': 'text/plain; charset=utf-8' }, body: submittedText
        });
        const currentText = activePath === path && loaded ? previewText : drafts.get(path)?.text ?? submittedText;
        pendingActions.delete(path);
        remember(path, currentText, submittedText);
        if (activePath === path) previewSavedText = submittedText;
        showToast(result.message);
      } catch (error) { showToast(error.message, true); }
      finally {
        pendingActions.delete(path);
        const draft = drafts.get(path);
        if (draft) remember(path, draft.text, draft.savedText);
        updateActions();
      }
    }

    async function restorePreview(module) {
      const path = `/api/modules/${module.id}/preview`;
      if (activePath !== path || !activeEditable || !loaded || pendingActions.has(path)) return;
      pendingActions.set(path, 'confirming');
      remember(path, previewText, previewSavedText);
      updateActions();
      try {
        if (!await askConfirmation('恢复转换结果？', `“${module.name}”的手动修改会被丢弃。`, '恢复')) return;
        const submittedText = activePath === path && loaded ? previewText : drafts.get(path)?.text;
        pendingActions.set(path, 'restore');
        updateActions();
        const text = await api(path, { method: 'DELETE' });
        const currentText = activePath === path && loaded ? previewText : drafts.get(path)?.text;
        const hasNewEdits = currentText !== undefined && currentText !== submittedText;
        pendingActions.delete(path);
        remember(path, hasNewEdits ? currentText : text, text);
        if (activePath === path) {
          requestGeneration += 1;
          const editor = documentRef.querySelector('#code-editor');
          if (hasNewEdits && loaded) previewSavedText = text;
          else if (editor) mountEditor(editor, path, text, text);
        }
        showToast(hasNewEdits ? '已恢复转换结果，操作期间的新修改仍保留为草稿' : '已恢复转换结果');
      } catch (error) { showToast(error.message, true); }
      finally {
        pendingActions.delete(path);
        const draft = drafts.get(path);
        if (draft) remember(path, draft.text, draft.savedText);
        updateActions();
      }
    }

    function retryPreview() {
      if (activePath && loadError) return loadPreview(activePath, activeEditable);
    }

    return {
      loadPreview, savePreview, restorePreview, retryPreview, deactivate,
      get text() { return previewText; },
      get savedText() { return previewSavedText; },
      get hasUnsavedChanges() { return drafts.size > 0 || pendingActions.size > 0; }
    };
  }
  global.SurgeRelayWebPreview = { createPreviewController };
})(globalThis);
