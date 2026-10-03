(function installSurgeRelayWebPreview(global) {
  function createPreviewController(dependencies = {}) {
    const api = dependencies.api;
    const documentRef = dependencies.document || global.document;
    const highlightCode = dependencies.highlightCode || (text => String(text || ''));
    const askConfirmation = dependencies.askConfirmation || (() => Promise.resolve(false));
    const showToast = dependencies.showToast || (() => {});
    const drafts = new Map();
    const storageKey = `surge-relay:drafts:v1:${dependencies.draftScope || global.location?.origin || 'local'}`;
    const legacyStorageKey = dependencies.legacyDraftScope ? `surge-relay:drafts:v1:${dependencies.legacyDraftScope}` : null;
    const migrationMarker = `${storageKey}:legacy-imported`;
    let migrateLegacy = false;
    let disposed = false;
    const now = dependencies.now || Date.now;
    const setTimer = dependencies.setTimeout || global.setTimeout;
    const clearTimer = dependencies.clearTimeout || global.clearTimeout;
    const indexedDB = dependencies.indexedDB ?? global.indexedDB;
    const dirtyPaths = new Set();
    let database = null;
    let persistenceQueue = Promise.resolve();
    let migrateLocal = false;
    let storage = null;
    let persistTimer = null;
    let persistenceError = '';
    try {
      storage = dependencies.storage ?? global.localStorage;
      const saved = JSON.parse(storage?.getItem(storageKey) || '[]');
      if (Array.isArray(saved)) for (const [path, draft] of saved) {
        if (/^\/api\/modules\/[^/]+\/preview$/.test(path) && typeof draft?.text === 'string' && typeof draft.savedText === 'string'
          && Number.isFinite(draft.updatedAt)) {
          drafts.set(path, { ...draft, recovered: true });
          dirtyPaths.add(path); migrateLocal = true;
        }
      }
    } catch (_) { persistenceError = '无法读取浏览器草稿；本次修改暂时只保留在内存中。'; }

    const editorBinding = {};
    const pendingActions = new Map();
    const deletedPaths = new Set();
    const viewPositions = new Map();
    const serverVersions = new Map();
    let previewText = '';
    let previewSavedText = '';
    let activePath = null;
    let activeEditable = false;
    let loaded = false;
    let loadError = '';
    let plainPreview = false;
    let requestGeneration = 0;

    function loadLegacyDrafts(records = [], imported = false) {
      if (!legacyStorageKey || imported) return;
      try {
        if (storage?.getItem(migrationMarker)) return;
        const saved = JSON.parse(storage?.getItem(legacyStorageKey) || '[]');
        const candidates = [...(Array.isArray(saved) ? saved : []), ...records.filter(record => record.scope === legacyStorageKey).map(record => [record.path, record])];
        for (const [path, draft] of candidates) {
          if (!/^\/api\/modules\/[^/]+\/preview$/.test(path) || typeof draft?.text !== 'string' || typeof draft.savedText !== 'string') continue;
          const existing = drafts.get(path);
          if (!existing || draft.updatedAt > existing.updatedAt) {
            drafts.set(path, { text: draft.text, savedText: draft.savedText, baseETag: draft.baseETag, updatedAt: draft.updatedAt, recovered: true });
            dirtyPaths.add(path);
          }
        }
        migrateLegacy = true;
      } catch (_) { persistenceError = '旧工作区草稿读取失败，原数据保留。'; }
    }

    const databaseReady = !indexedDB ? (loadLegacyDrafts(), Promise.resolve(null)) : new Promise(resolve => {
      let request;
      try { request = indexedDB.open('SurgeRelayBrowserDrafts', 2); }
      catch (_) { loadLegacyDrafts(); resolve(null); return; }
      request.onupgradeneeded = () => {
        const store = request.result.objectStoreNames.contains('drafts') ? request.transaction.objectStore('drafts') : request.result.createObjectStore('drafts', { keyPath: 'key' });
        if (!store.indexNames.contains('scope')) store.createIndex('scope', 'scope', { unique: false });
      };
      request.onerror = () => { loadLegacyDrafts(); resolve(null); };
      request.onblocked = () => resolve(null);
      request.onsuccess = () => {
        const db = request.result;
        if (disposed) { db.close(); resolve(null); return; }
        db.onversionchange = () => { db.close(); database = null; };
        let transaction;
        try { transaction = db.transaction('drafts', 'readonly'); }
        catch (_) { db.close(); resolve(null); return; }
        const scoped = transaction.objectStore('drafts').index('scope');
        const read = scoped.getAll(storageKey);
        function mergeCurrent(records) {
          if (disposed) return;
          for (const record of records) {
            if (!/^\/api\/modules\/[^/]+\/preview$/.test(record.path)
              || typeof record.text !== 'string' || typeof record.savedText !== 'string') continue;
            const local = drafts.get(record.path);
            if (!local || record.updatedAt >= local.updatedAt) {
              drafts.set(record.path, { text: record.text, savedText: record.savedText, baseETag: record.baseETag, updatedAt: record.updatedAt, recovered: true });
              dirtyPaths.delete(record.path);
            }
          }
        }
        read.onsuccess = () => {
          if (disposed) return;
          const records = read.result;
          if (legacyStorageKey && !records.some(record => record.key === migrationMarker)) {
            const legacy = scoped.getAll(legacyStorageKey);
            legacy.onsuccess = () => { if (!disposed) { loadLegacyDrafts(legacy.result); mergeCurrent(records); } };
          } else mergeCurrent(records);
        };
        transaction.oncomplete = () => { database = db; resolve(db); };
        transaction.onerror = transaction.onabort = () => { db.close(); resolve(null); };
      };
    });

    if (typeof api !== 'function') throw new Error('web-preview.js requires an api function');

    function updateActions() {
      if (disposed) return;
      const pending = pendingActions.get(activePath);
      const draft = drafts.get(activePath);
      const recoveryPending = draft?.recovered;
      const save = documentRef.querySelector('[data-action="save-preview"]');
      if (save) {
        save.hidden = Boolean(loadError);
        save.disabled = !loaded || recoveryPending || Boolean(pending) || previewText === previewSavedText;
        save.textContent = pending === 'save' ? '写入中…' : '写入';
      }
      const restore = documentRef.querySelector('[data-action="restore-preview"]');
      if (restore) { restore.hidden = Boolean(loadError); restore.disabled = !loaded || recoveryPending || Boolean(pending); }
      const copy = documentRef.querySelector('[data-action="copy-preview"]');
      if (copy) { copy.hidden = Boolean(loadError); copy.disabled = !loaded; }
      const retry = documentRef.querySelector('[data-action="retry-preview"]');
      if (retry) retry.hidden = !loadError;
      for (const action of ['recover-draft', 'discard-draft', 'compare-preview']) {
        const button = documentRef.querySelector(`[data-action="${action}"]`);
        if (button) { button.hidden = action === 'recover-draft' ? !recoveryPending : action === 'compare-preview' ? !draft?.conflict : !draft; button.disabled = !loaded || Boolean(pending); }
      }
      const draftMessage = recoveryPending ? (draft.conflict ? '发现浏览器草稿，但服务器内容已变化。可恢复草稿查看；写入前需要确认覆盖服务器版本。' : '发现浏览器草稿，可恢复继续编辑，或删除草稿保留服务器版本。')
        : draft?.conflict ? '服务器内容已变化；当前草稿尚未写入，写入前需要确认覆盖。' : '';
      const comparison = documentRef.querySelector('#server-preview');
      if (comparison && !draft?.conflict) comparison.hidden = true;
      if (comparison && !comparison.hidden && serverVersions.has(activePath) && comparison.textContent !== serverVersions.get(activePath).text) comparison.textContent = serverVersions.get(activePath).text;
      const message = documentRef.querySelector('#preview-message');
      const messageText = [loadError, draftMessage, persistenceError].filter(Boolean).join(' ');
      if (message) { message.hidden = !messageText; message.textContent = messageText; }
      const status = documentRef.querySelector('#preview-status');
      if (status) {
        const dirty = activeEditable && previewText !== previewSavedText;
        const state = loadError ? 'error' : !loaded ? 'loading' : pending === 'save' ? 'saving' : pending === 'restore' ? 'restoring' : dirty ? 'dirty' : 'saved';
        const label = { error: '读取失败', loading: '正在载入', saving: '正在写入…', restoring: '正在恢复…', dirty: '未保存', saved: activeEditable ? '已保存' : plainPreview ? '大文件 · 纯文本显示' : '只读预览' }[state];
        if (status.textContent !== label) status.textContent = label;
        status.dataset.state = state;
      }
    }

    function persistenceFailed() {
      if (!persistenceError) showToast('草稿未能保存到浏览器：存储不可用或容量已满。修改仍在本页内存中，请先复制备份。', true);
      persistenceError = '草稿未持久化：请保持本页打开或复制备份。可删除不需要的浏览器草稿后重试。';
      updateActions();
    }

    function flushLocalDrafts() {
      try {
        if (!storage && drafts.size === 0) { persistenceError = ''; updateActions(); return; }
        if (!storage) throw new Error('storage unavailable');
        const data = JSON.stringify([...drafts].map(([path, draft]) => [path, { text: draft.text, savedText: draft.savedText, updatedAt: draft.updatedAt, baseETag: draft.baseETag }]));
        if (data.length > 1536 * 1024) throw new Error('IndexedDB required for large drafts');
        if (drafts.size) storage.setItem(storageKey, data); else storage.removeItem(storageKey);
        if (migrateLegacy) { storage.setItem(migrationMarker, 'true'); migrateLegacy = false; }
        persistenceError = '';
        updateActions();
      } catch (_) { persistenceFailed(); }
    }

    function flushDrafts() {
      if (disposed) return;
      if (persistTimer != null) clearTimer?.(persistTimer);
      persistTimer = null;
      if (!indexedDB) return flushLocalDrafts();
      persistenceQueue = persistenceQueue.then(async () => {
        await databaseReady;
        if (disposed) return;
        if (!database) return flushLocalDrafts();
        const paths = [...dirtyPaths];
        const snapshot = new Map(paths.map(path => [path, drafts.get(path)]));
        paths.forEach(path => dirtyPaths.delete(path));
        try {
          await new Promise((resolve, reject) => {
            const transaction = database.transaction('drafts', 'readwrite');
            const store = transaction.objectStore('drafts');
            if (migrateLegacy) store.put({ key: migrationMarker, scope: storageKey, legacyImported: true });
            for (const [path, draft] of snapshot) {
              const key = `${storageKey}:${path}`;
              if (draft) store.put({ key, scope: storageKey, path, text: draft.text, savedText: draft.savedText, baseETag: draft.baseETag, updatedAt: draft.updatedAt });
              else store.delete(key);
            }
            transaction.oncomplete = resolve;
            transaction.onerror = transaction.onabort = () => reject(transaction.error);
          });
          if (migrateLocal) { storage?.removeItem(storageKey); migrateLocal = false; }
          migrateLegacy = false;
          persistenceError = '';
          updateActions();
        } catch (_) {
          paths.forEach(path => dirtyPaths.add(path));
          persistenceFailed();
        }
      });
      return persistenceQueue;
    }

    function remember(path, text, savedText) {
      if (disposed || deletedPaths.has(path)) return;
      dirtyPaths.add(path);
      if (text === savedText && !pendingActions.has(path) && !drafts.get(path)?.conflict) drafts.delete(path);
      else drafts.set(path, { ...drafts.get(path), text, savedText, baseETag: drafts.get(path)?.baseETag || serverVersions.get(path)?.etag, updatedAt: now(), recovered: false });
      if (persistTimer != null) clearTimer?.(persistTimer);
      if (setTimer) persistTimer = setTimer(flushDrafts, 400);
    }

    function mountEditor(editor, path, text, savedText) {
      loaded = true;
      previewText = text;
      previewSavedText = savedText;
      editor.value = text;
      editor.disabled = Boolean(drafts.get(path)?.recovered);
      editor.relayPreviewPath = path;
      const position = viewPositions.get(path);
      if (position) {
        editor.setSelectionRange?.(position.start, position.end);
        editor.scrollTop = position.scrollTop;
        editor.scrollLeft = position.scrollLeft;
      }
      updateActions();
      if (editor.relayPreviewBound === editorBinding) return;
      editor.relayPreviewBound = editorBinding;
      editor.addEventListener('input', () => {
        const path = editor.relayPreviewPath;
        if (activePath !== path) return;
        previewText = editor.value;
        remember(path, previewText, previewSavedText);
        updateActions();
      });
    }

    function deactivate() {
      if (drafts.size) flushDrafts();
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
      await databaseReady;
      if (generation !== requestGeneration) return;
      if ((migrateLocal || migrateLegacy) && database) await flushDrafts();
      activePath = path;
      activeEditable = editable;
      loaded = false;
      loadError = '';
      plainPreview = false;
      previewText = '';
      previewSavedText = '';
      const editor = editable ? documentRef.querySelector('#code-editor') : null;
      const draft = drafts.get(path);
      if (editable && editor && draft && !draft.recovered) {
        mountEditor(editor, path, draft.text, draft.savedText);
        return;
      }
      if (editor) { editor.disabled = true; editor.value = '正在载入…'; }
      updateActions();
      try {
        const response = await api(path, { withResponseMetadata: true });
        const text = typeof response === 'string' ? response : response.body;
        const etag = typeof response === 'string' ? null : response.etag;
        if (generation !== requestGeneration || activePath !== path) return;
        serverVersions.set(path, { text, etag, conditional: typeof response !== 'string' });
        if (editable) {
          const target = documentRef.querySelector('#code-editor');
          if (!target) return;
          if (draft?.recovered) {
            if (draft.text === text) { drafts.delete(path); dirtyPaths.add(path); flushDrafts(); }
            else { draft.conflict = draft.savedText !== text; if (!draft.conflict) draft.baseETag = etag; }
          }
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
      if (drafts.get(path)?.recovered) return;
      let expectedETag = drafts.get(path)?.baseETag || serverVersions.get(path)?.etag;
      if (drafts.get(path)?.conflict) {
        pendingActions.set(path, 'confirming'); updateActions();
        const accepted = await askConfirmation('覆盖已变化的服务器内容？', '此草稿基于旧版本。写入会替换当前服务器内容，请确认已比较并保留需要的修改。', '确认写入');
        pendingActions.delete(path); updateActions();
        if (!accepted || activePath !== path || !loaded) return;
        expectedETag = serverVersions.get(path)?.etag;
      }
      if (drafts.get(path)?.conflict && !serverVersions.has(path)) { showToast('无法取得最新服务器版本，请重新载入后比较。', true); return; }
      if (!expectedETag && serverVersions.get(path)?.conditional) { showToast('服务器未提供内容版本，无法安全写入。请重新载入后重试。', true); return; }
      const submittedText = previewText;
      pendingActions.set(path, 'save');
      remember(path, submittedText, previewSavedText);
      updateActions();
      try {
        const response = await api(path, {
          method: 'PUT', headers: { 'Content-Type': 'text/plain; charset=utf-8', ...(expectedETag ? { 'If-Match': expectedETag } : {}) }, body: submittedText, withResponseMetadata: true
        });
        const result = response.body || response;
        const savedText = typeof result.content === 'string' ? result.content : submittedText;
        serverVersions.set(path, { text: savedText, etag: response.etag, conditional: 'etag' in response });
        const currentText = activePath === path && loaded ? previewText : drafts.get(path)?.text ?? submittedText;
        pendingActions.delete(path);
        if (drafts.has(path)) { drafts.get(path).conflict = false; drafts.get(path).baseETag = response.etag; }
        const nextText = currentText === submittedText ? savedText : currentText;
        remember(path, nextText, savedText);
        if (activePath === path) {
          previewSavedText = savedText;
          if (loaded && currentText === submittedText) {
            previewText = savedText;
            const editor = documentRef.querySelector('#code-editor');
            if (editor) editor.value = savedText;
          }
        }
        showToast(result.message);
      } catch (error) {
        if (error.status === 412 || error.status === 409) {
          const draft = drafts.get(path);
          if (draft) draft.conflict = true;
          try {
            const latest = await api(path, { withResponseMetadata: true });
            serverVersions.set(path, { text: latest.body, etag: latest.etag, conditional: true });
          } catch (_) { serverVersions.delete(path); }
          showToast(error.status === 409 ? '服务器正在处理其他操作，未写入。草稿已保留，请稍后比较服务器版本再写入。' : '服务器版本已变化，未写入。草稿已保留，请查看服务器版本并比较后再写入。', true);
        } else showToast(error.message, true);
      }
      finally {
        pendingActions.delete(path);
        const draft = drafts.get(path);
        if (draft) remember(path, draft.text, draft.savedText);
        flushDrafts();
        updateActions();
      }
    }

    async function restorePreview(module) {
      const path = `/api/modules/${module.id}/preview`;
      if (activePath !== path || !activeEditable || !loaded || pendingActions.has(path) || drafts.get(path)?.recovered) return;
      const expectedETag = drafts.get(path)?.conflict ? serverVersions.get(path)?.etag : drafts.get(path)?.baseETag || serverVersions.get(path)?.etag;
      if (!expectedETag && serverVersions.get(path)?.conditional) { showToast('服务器未提供内容版本，无法安全恢复。请重新载入后重试。', true); return; }
      pendingActions.set(path, 'confirming');
      remember(path, previewText, previewSavedText);
      updateActions();
      try {
        if (!await askConfirmation('恢复转换结果？', `“${module.name}”的手动修改会被丢弃。`, '恢复')) return;
        const submittedText = activePath === path && loaded ? previewText : drafts.get(path)?.text;
        pendingActions.set(path, 'restore');
        updateActions();
        const response = await api(path, { method: 'DELETE', headers: expectedETag ? { 'If-Match': expectedETag } : {}, withResponseMetadata: true });
        const text = typeof response === 'string' ? response : response.body;
        serverVersions.set(path, { text, etag: response.etag, conditional: typeof response !== 'string' });
        const currentText = activePath === path && loaded ? previewText : drafts.get(path)?.text;
        const hasNewEdits = currentText !== undefined && currentText !== submittedText;
        pendingActions.delete(path);
        if (drafts.has(path)) { drafts.get(path).conflict = false; drafts.get(path).baseETag = response.etag; }
        remember(path, hasNewEdits ? currentText : text, text);
        if (activePath === path) {
          requestGeneration += 1;
          const editor = documentRef.querySelector('#code-editor');
          if (hasNewEdits && loaded) previewSavedText = text;
          else if (editor) mountEditor(editor, path, text, text);
        }
        showToast(hasNewEdits ? '已恢复转换结果，操作期间的新修改仍保留为草稿' : '已恢复转换结果');
      } catch (error) {
        if (error.status === 412 || error.status === 409) {
          const draft = drafts.get(path);
          if (draft) draft.conflict = true;
          try {
            const latest = await api(path, { withResponseMetadata: true });
            serverVersions.set(path, { text: latest.body, etag: latest.etag, conditional: true });
          } catch (_) { serverVersions.delete(path); }
          showToast('未恢复转换结果：服务器版本已变化或正在处理其他操作。草稿已保留，请先比较服务器版本。', true);
        } else showToast(error.message, true);
      }
      finally {
        pendingActions.delete(path);
        const draft = drafts.get(path);
        if (draft) remember(path, draft.text, draft.savedText);
        flushDrafts();
        updateActions();
      }
    }

    async function refreshVersionBaseline(moduleID) {
      const path = `/api/modules/${moduleID}/preview`;
      const priorVersion = serverVersions.get(path);
      try {
        const response = await api(path, { withResponseMetadata: true });
        if (deletedPaths.has(path) || serverVersions.get(path) !== priorVersion) return;
        const text = typeof response === 'string' ? response : response.body;
        const etag = typeof response === 'string' ? null : response.etag;
        serverVersions.set(path, { text, etag, conditional: typeof response !== 'string' });
        const draft = drafts.get(path);
        if (draft) {
          draft.conflict = draft.savedText !== text;
          if (!draft.conflict) draft.baseETag = etag;
          dirtyPaths.add(path);
          await flushDrafts();
        } else if (activePath === path && loaded) {
          const editor = documentRef.querySelector('#code-editor');
          if (editor) mountEditor(editor, path, text, text);
        }
        updateActions();
      } catch (_) {
        const draft = drafts.get(path);
        if (draft) { draft.conflict = true; draft.recovered = true; }
        serverVersions.delete(path);
        showToast('缓存已恢复，但暂时无法读取新版本。草稿已保留，请重新打开预览再比较。', true);
        updateActions();
      }
    }

    function comparePreview() {
      const comparison = documentRef.querySelector('#server-preview');
      const version = serverVersions.get(activePath);
      if (!comparison || !version) return;
      comparison.textContent = version.text;
      comparison.hidden = !comparison.hidden;
      if (!comparison.hidden) comparison.focus?.({ preventScroll: true });
    }

    function recoverDraft() {
      const draft = drafts.get(activePath);
      const editor = documentRef.querySelector('#code-editor');
      if (!draft?.recovered || !editor || !loaded || pendingActions.has(activePath)) return;
      draft.recovered = false;
      mountEditor(editor, activePath, draft.text, draft.savedText);
      editor.focus?.({ preventScroll: true });
    }

    async function discardDraft() {
      const path = activePath;
      if (!drafts.has(path) || pendingActions.has(path)) return;
      const originalText = drafts.get(path).text;
      pendingActions.set(path, 'confirming'); updateActions();
      const accepted = await askConfirmation('删除浏览器草稿？', '仅删除未写入的浏览器草稿，服务器内容保持不变。', '删除草稿');
      pendingActions.delete(path);
      if (accepted && drafts.get(path)?.text === originalText) {
        drafts.delete(path); dirtyPaths.add(path); flushDrafts();
        if (activePath === path) await loadPreview(path, true);
      }
      updateActions();
    }

    function forgetModule(id) {
      deletedPaths.add(`/api/modules/${id}/preview`);
      drafts.delete(`/api/modules/${id}/preview`);
      dirtyPaths.add(`/api/modules/${id}/preview`);
      flushDrafts();
    }

    function retryPreview() {
      if (activePath && loadError) return loadPreview(activePath, activeEditable);
    }

    function dispose() {
      disposed = true; requestGeneration += 1;
      if (persistTimer != null) clearTimer?.(persistTimer);
      activePath = null; loaded = false;
      previewText = ''; previewSavedText = '';
      drafts.clear(); pendingActions.clear(); dirtyPaths.clear(); serverVersions.clear(); viewPositions.clear(); deletedPaths.clear();
      database?.close?.(); database = null;
    }
    async function importMemoryDrafts(entries) {
      await databaseReady;
      for (const [path, draft] of entries) {
        const saved = drafts.get(path);
        if (!saved || draft.updatedAt >= saved.updatedAt) { drafts.set(path, { ...draft, recovered: true }); dirtyPaths.add(path); }
      }
    }

    return {
      ready: databaseReady, dispose, importMemoryDrafts,
      snapshotDrafts: () => [...drafts].map(([path, draft]) => [path, { ...draft }]),
      get hasPersistenceError() { return Boolean(persistenceError); },
      loadPreview, savePreview, restorePreview, retryPreview, deactivate, refreshVersionBaseline, comparePreview, recoverDraft, discardDraft, forgetModule, flushDrafts,
      get text() { return previewText; },
      get savedText() { return previewSavedText; },
      get hasUnsavedChanges() { return drafts.size > 0 || pendingActions.size > 0; }
    };
  }
  function createWorkspacePreviewController(dependencies = {}) {
    const origin = dependencies.draftScope || global.location?.origin || 'local';
    const memoryDrafts = new Map();
    let current = null;
    let workspaceID = null;
    let currentRuntimeID = null;
    let switching = false;
    let transitionCount = 0;
    let hasKnownWorkspace = false;
    let transitions = Promise.resolve();
    function switchWorkspace(workspace, runtimeID = null) {
      if (hasKnownWorkspace && !workspace?.id) return Promise.reject(new Error('缺少工作区信息，未切换草稿。'));
      const id = workspace?.id ? String(workspace.id) : 'legacy-origin';
      if (workspace?.id) hasKnownWorkspace = true;
      if (!switching && id === workspaceID && runtimeID === currentRuntimeID) return Promise.resolve(false);
      switching = true; transitionCount += 1;
      transitions = transitions.catch(() => {}).then(async () => {
        if (id === workspaceID && runtimeID === currentRuntimeID) return false;
        if (current) {
          await current.flushDrafts();
          const unsaved = current.hasPersistenceError ? current.snapshotDrafts() : [];
          if (unsaved.length) memoryDrafts.set(workspaceID, unsaved);
          else memoryDrafts.delete(workspaceID);
          current.dispose(); current = null;
        }
        const scope = workspace?.id ? `${origin}:workspace:${encodeURIComponent(id)}` : origin;
        let instance;
        instance = createPreviewController({
          ...dependencies, draftScope: scope,
          legacyDraftScope: workspace?.isLegacyDefault === true ? origin : null,
          api: async (...args) => {
            if (switching || current !== instance) throw new Error('工作区已切换，旧操作已停止。');
            const result = await dependencies.api(...args);
            if (switching || current !== instance) throw new Error('工作区已切换，旧操作已停止。');
            return result;
          },
          showToast: (...args) => { if (current === instance) dependencies.showToast?.(...args); }
        });
        current = instance; workspaceID = id; currentRuntimeID = runtimeID;
        await instance.ready;
        if (memoryDrafts.has(id)) await instance.importMemoryDrafts(memoryDrafts.get(id));
        await instance.flushDrafts();
        if (!instance.hasPersistenceError) memoryDrafts.delete(id);
        return true;
      }).finally(() => { transitionCount -= 1; switching = transitionCount > 0; });
      return transitions;
    }
    const methods = ['loadPreview', 'savePreview', 'restorePreview', 'retryPreview', 'deactivate', 'refreshVersionBaseline', 'comparePreview', 'recoverDraft', 'discardDraft', 'forgetModule'];
    return {
      switchWorkspace,
      flushDrafts: () => current?.flushDrafts(),
      ...Object.fromEntries(methods.map(name => [name, (...args) => switching ? undefined : current?.[name](...args)])),
      get text() { return current?.text || ''; },
      get savedText() { return current?.savedText || ''; },
      get hasUnsavedChanges() { return Boolean(current?.hasUnsavedChanges || memoryDrafts.size); }
    };
  }
  global.SurgeRelayWebPreview = { createPreviewController, createWorkspacePreviewController };
})(globalThis);
