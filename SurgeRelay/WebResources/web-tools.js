(function installSurgeRelayWebTools(global) {
  const defaults = {
    kind: 'ruleSet', sourceURL: '', sourceText: '', outputName: 'Converted', outputFormat: 'surge', sourceFormat: 'quantumultX',
    ruleOutputStyle: 'ruleSet', policy: 'REJECT', includeKeywords: '', excludeKeywords: '', requestHeaders: '', noResolve: false, sni: '',
    compatibilityOnly: false, wrapResponse: false, prependScript: '', evalScriptOriginal: '', evalScriptModified: '', evalURLOriginal: '', evalURLModified: ''
  };

  function createToolsController(dependencies) {
    const { ui, api, copyText } = dependencies;
    const getState = dependencies.getState;
    const getSelectedID = dependencies.getSelectedID;
    const documentRef = dependencies.document || global.document;
    const format = global.SurgeRelayWebFormat;
    const outputFormats = global.SurgeRelayWebOptions.outputFormats;
    const drafts = new Map();
    let workspaceID = null;
    let runtimeID = null;
    let generation = 0;

    function current() {
      if (!drafts.has(workspaceID)) drafts.set(workspaceID, { draft: { ...defaults }, revision: 0, result: null, error: '', pending: false });
      return drafts.get(workspaceID);
    }

    function switchWorkspace(workspace, nextRuntimeID) {
      const nextID = workspace?.id || 'legacy-origin';
      if (nextID === workspaceID && nextRuntimeID === runtimeID) return;
      if (workspaceID != null) current().pending = false;
      workspaceID = nextID; runtimeID = nextRuntimeID; generation += 1;
      current();
    }

    function selected() { return getSelectedID() === 'tools'; }
    function isRuleSet() { return current().draft.kind === 'ruleSet'; }
    function canWrap() { const draft = current().draft; return draft.sourceFormat === 'quantumultX' && draft.outputFormat !== 'quantumultX'; }
    function canUseDomainStyle() { return ['surge', 'egern', 'stash'].includes(current().draft.outputFormat); }

    function field(name, title, { multiline = false, placeholder = '' } = {}) {
      const value = format.escapeAttribute(current().draft[name]);
      return `<label class="tool-field"><span>${format.escapeHTML(title)}</span>${multiline
        ? `<textarea name="${name}" data-tool-field="${name}" rows="4" spellcheck="false" placeholder="${format.escapeAttribute(placeholder)}">${format.escapeHTML(current().draft[name])}</textarea>`
        : `<input name="${name}" data-tool-field="${name}" value="${value}" placeholder="${format.escapeAttribute(placeholder)}">`}</label>`;
    }

    function toggle(name, title) {
      return `<label class="tool-toggle"><input type="checkbox" name="${name}" data-tool-field="${name}" ${current().draft[name] ? 'checked' : ''}><span>${format.escapeHTML(title)}</span></label>`;
    }

    function select(name, title, options) {
      return `<label class="tool-field"><span>${title}</span><select name="${name}" data-tool-field="${name}">${options.map(([value, label]) => `<option value="${value}" ${current().draft[name] === value ? 'selected' : ''}>${format.escapeHTML(label)}</option>`).join('')}</select></label>`;
    }

    function render() {
      if (!selected()) return;
      const draft = current().draft;
      ui.mobileTitle.textContent = '转换工具';
      const sourceClient = isRuleSet() ? '' : select('sourceFormat', '脚本源客户端', [['quantumultX', 'Quantumult X'], ['surge', 'Surge'], ['loon', 'Loon']]);
      const styleOptions = [['ruleSet', '完整规则集'], ...(canUseDomainStyle() ? [['domainSet', '仅域名'], ['nonDomainRules', '非域名规则']] : [])];
      const ruleOptions = isRuleSet() ? `${select('ruleOutputStyle', '规则输出', styleOptions)}${draft.outputFormat === 'quantumultX' ? field('policy', '规则策略', { placeholder: 'REJECT、DIRECT 或已有策略名称' }) : ''}` : '';
      const advanced = isRuleSet()
        ? `${field('includeKeywords', '释放注释关键字', { placeholder: '多项使用 + 分隔' })}${field('excludeKeywords', '删除关键字', { placeholder: '多项使用 + 分隔' })}${toggle('noResolve', '添加 no-resolve')}${field('sni', 'SNI')}`
        : `${toggle('compatibilityOnly', '仅转换兼容性')}${canWrap() ? toggle('wrapResponse', '响应脚本封装') : ''}${field('prependScript', '脚本前置代码', { multiline: true })}`;
      ui.detail.innerHTML = `<div class="detail-stage"><header class="workspace-heading"><p class="eyebrow">CONVERT</p><h1>转换工具</h1><p>把规则或脚本转换为所选客户端的文件，直接复制或下载结果。</p></header>
        <form id="conversion-tool-form" class="conversion-tool-form">
          <section class="workspace-panel tool-panel"><div class="tool-field-grid">${select('kind', '转换类型', [['ruleSet', '规则集'], ['script', '脚本']])}${select('outputFormat', '输出客户端', outputFormats.map(item => [item.id, item.title]))}${sourceClient}${ruleOptions}${field('outputName', '输出文件名', { placeholder: 'Converted' })}</div></section>
          <section class="workspace-panel tool-panel">${field('sourceURL', '来源地址', { placeholder: 'HTTP/HTTPS 或本地文件地址' })}${field('sourceText', '或直接粘贴内容', { multiline: true, placeholder: isRuleSet() ? 'DOMAIN-SUFFIX,example.com' : '粘贴 JavaScript' })}</section>
          <details class="workspace-panel tool-panel"><summary>高级转换选项</summary><div class="tool-field-grid">${advanced}</div>${field('requestHeaders', '来源请求 Header', { multiline: true, placeholder: 'User-Agent: Script-Hub' })}${field('evalScriptOriginal', '转换前处理代码', { multiline: true })}${field('evalScriptModified', '转换后处理代码', { multiline: true })}<div class="tool-field-grid">${field('evalURLOriginal', '转换前处理代码 URL')}${field('evalURLModified', '转换后处理代码 URL')}</div></details>
          <div class="operation-buttons"><button type="submit" class="button primary" id="tool-convert">转换</button><button type="button" class="button" data-tool-action="cancel" id="tool-cancel" hidden>取消转换</button><span id="tool-status" role="status"></span></div>
          <p id="tool-error" class="tool-error" role="alert" hidden></p>
        </form><section id="tool-result" class="workspace-panel tool-panel" hidden></section></div>`;
      patchStatus();
    }

    function patchStatus() {
      if (!selected()) return;
      const entry = current();
      const activity = getState()?.activity || {};
      const convert = ui.detail.querySelector('#tool-convert');
      if (convert) convert.disabled = Boolean(entry.pending || activity.isWorking);
      const cancel = ui.detail.querySelector('#tool-cancel');
      if (cancel) { cancel.hidden = !entry.pending; cancel.disabled = activity.kind !== 'convertingTool' || activity.canCancel !== true || activity.cancellationRequested === true; }
      const status = ui.detail.querySelector('#tool-status');
      if (status) status.textContent = entry.pending ? activity.cancellationRequested ? '正在取消…' : '正在转换…' : activity.isWorking ? activity.title || '当前任务正在运行，请完成后再转换。' : '';
      const error = ui.detail.querySelector('#tool-error');
      if (error) { error.textContent = entry.error; error.hidden = !entry.error; }
      const result = ui.detail.querySelector('#tool-result');
      if (result) {
        result.hidden = !entry.result;
        const content = entry.result ? `<div class="workspace-section-heading"><h2>${format.escapeHTML(entry.result.fileName)}</h2><div class="operation-buttons"><button type="button" class="button" data-tool-action="copy">复制结果</button><button type="button" class="button" data-tool-action="download">下载文件</button></div></div><textarea class="tool-result-text" readonly spellcheck="false" aria-label="转换结果">${format.escapeHTML(entry.result.content)}</textarea>` : '';
        if (result.innerHTML !== content) result.innerHTML = content;
      }
    }

    function handleInput(event) {
      const element = event.target.closest?.('[data-tool-field]');
      if (!element || !selected()) return;
      const name = element.dataset.toolField;
      const entry = current();
      const value = element.type === 'checkbox' ? element.checked : element.value;
      if (entry.draft[name] === value) return;
      entry.draft[name] = value;
      if (name === 'sourceURL' && element.value) entry.draft.sourceText = '';
      if (name === 'sourceText' && element.value) entry.draft.sourceURL = '';
      if (!canUseDomainStyle()) entry.draft.ruleOutputStyle = 'ruleSet';
      if (!canWrap()) entry.draft.wrapResponse = false;
      entry.revision += 1; entry.result = null; entry.error = '';
      if (['kind', 'outputFormat', 'sourceFormat'].includes(name)) render();
      else {
        for (const other of ['sourceURL', 'sourceText']) {
          const target = ui.detail.querySelector(`[data-tool-field="${other}"]`);
          if (target && other !== name) target.value = entry.draft[other];
        }
        patchStatus();
      }
    }

    async function convert() {
      const entry = current();
      if (entry.pending || getState()?.activity?.isWorking) return;
      const epoch = generation;
      const revision = entry.revision;
      const draft = { ...entry.draft };
      const request = {};
      entry.pending = request; entry.result = null; entry.error = ''; patchStatus();
      try {
        const result = await api('/api/tools/convert', { method: 'POST', json: draft });
        if (epoch === generation && entry.revision === revision) entry.result = result;
      } catch (error) {
        if (epoch === generation && entry.revision === revision) entry.error = error.message;
      } finally {
        if (entry.pending === request) entry.pending = false;
        if (epoch === generation) patchStatus();
      }
    }

    async function handleClick(event) {
      const button = event.target.closest?.('[data-tool-action]');
      if (!button || !selected() || button.disabled) return;
      const action = button.dataset.toolAction;
      const result = current().result;
      if (action === 'copy' && result) await copyText(result.content, button);
      else if (action === 'download' && result) {
        if (dependencies.downloadResult) { dependencies.downloadResult(result); return; }
        const url = global.URL.createObjectURL(new global.Blob([result.content], { type: 'text/plain;charset=utf-8' }));
        const link = documentRef.createElement('a');
        link.href = url; link.download = result.fileName; link.click();
        global.URL.revokeObjectURL(url);
      } else if (action === 'cancel' && current().pending) {
        const activity = getState()?.activity;
        if (activity?.kind !== 'convertingTool' || activity.canCancel !== true || activity.cancellationRequested) return;
        const epoch = generation;
        try { await api('/api/cancel-work', { method: 'POST' }); }
        catch (error) { if (epoch === generation) { current().error = error.message; patchStatus(); } }
      }
    }

    function handleSubmit(event) {
      if (!event.target.closest?.('#conversion-tool-form')) return;
      event.preventDefault();
      return convert();
    }

    ui.detail.addEventListener('input', handleInput);
    ui.detail.addEventListener('change', handleInput);
    ui.detail.addEventListener('click', handleClick);
    ui.detail.addEventListener('submit', handleSubmit);
    return { switchWorkspace, render, patchStatus, convert, handleInput, handleClick, handleSubmit, get draft() { return current().draft; }, get result() { return current().result; } };
  }

  global.SurgeRelayWebTools = { defaults, createToolsController };
})(globalThis);
