(function installSurgeRelayWebMarkup(global) {
  const format = global.SurgeRelayWebFormat;
  if (!format) throw new Error('web-format.js must load before web-markup.js');

  const { formatDate, escapeHTML, escapeAttribute } = format;

  function detailRow(icon, label, value, raw = false, copyValue = null) {
    const renderedValue = raw ? value : escapeHTML(String(value ?? '—'));
    const copyButton = copyValue
      ? `<button class="button detail-copy" data-action="copy" data-value="${escapeAttribute(copyValue)}"><span class="symbol" data-symbol="copy"></span>拷贝</button>`
      : '';
    const valueClass = copyValue ? 'detail-value detail-value-with-action' : 'detail-value';
    return `<div class="detail-row"><div class="detail-label"><span class="symbol" data-symbol="${escapeAttribute(icon)}"></span><span>${escapeHTML(label)}</span></div><div class="${valueClass}"><span class="detail-value-text">${renderedValue}</span>${copyButton}</div></div>`;
  }

  function copyableValueSection(title, value, buttonLabel = '拷贝地址') {
    if (!value) return '';
    return `<section class="form-section-view"><h3 class="section-heading">${escapeHTML(title)}</h3><div class="group-box"><div class="detail-row action-row"><div class="detail-value monospaced">${escapeHTML(value)}</div><div><button class="button" data-action="copy" data-value="${escapeAttribute(value)}"><span class="symbol" data-symbol="copy"></span>${escapeHTML(buttonLabel)}</button></div></div></div></section>`;
  }

  function previewShell(label, editable) {
    return `<section class="preview-shell"><div class="preview-toolbar"><span class="preview-label">${escapeHTML(label)}</span><button class="button" data-action="copy-preview"><span class="symbol" data-symbol="doc.on.doc"></span>拷贝全部</button>${editable ? `<button class="button" data-action="restore-preview"><span class="symbol" data-symbol="arrow.uturn.backward"></span>恢复</button><button class="button primary" data-action="save-preview" disabled>写入</button>` : ''}</div>${editable ? '<textarea class="code-editor" id="code-editor" spellcheck="false" aria-label="模块内容">正在载入…</textarea>' : '<pre class="code-view" id="code-view">正在载入…</pre>'}</section>`;
  }

  function publishFileList(title, files, destructive = false) {
    if (!files?.length) return '';
    const visible = files.slice(0, 8).map(file => `<code>${escapeHTML(file)}</code>`).join('');
    const overflow = files.length > 8 ? `<small>另有 ${files.length - 8} 个文件</small>` : '';
    return `<div class="publish-file-group ${destructive ? 'destructive' : ''}"><strong>${escapeHTML(title)} ${files.length} 个文件</strong>${visible}${overflow}</div>`;
  }

  function latestPublishSection(publish) {
    if (!publish) return '';
    const publishedFiles = publish.publishedFiles || [];
    const deletedFiles = publish.deletedFiles || [];
    const commitText = publish.commitSHA ? publish.commitSHA.slice(0, 8) : '未记录';
    const commitValue = publish.commitURL
      ? `<a href="${escapeAttribute(publish.commitURL)}" target="_blank" rel="noreferrer">Commit ${escapeHTML(commitText)}</a>`
      : `Commit ${escapeHTML(commitText)}`;
    const files = publishFileList('上传/更新', publishedFiles) + publishFileList('删除', deletedFiles, true);
    return `<section class="form-section-view"><h3 class="section-heading">最近 GitHub 发布</h3><div class="group-box">
    ${detailRow('link', '提交', commitValue, true)}
    ${detailRow('clock', '时间', formatDate(publish.date, '—'))}
    ${detailRow('doc.on.doc', '变更', `${publishedFiles.length} 个上传/更新 · ${deletedFiles.length} 个删除`)}
    ${files ? `<div class="publish-file-list">${files}</div>` : ''}
  </div></section>`;
  }

  function argumentMarkup(argument) {
    const isBoolean = ['true', 'false'].includes(String(argument.defaultValue).toLowerCase());
    const control = isBoolean
      ? `<label class="module-toggle argument-toggle"><input type="checkbox" data-argument-key="${escapeAttribute(argument.key)}" data-default="${escapeAttribute(argument.defaultValue)}" ${String(argument.value).toLowerCase() === 'true' ? 'checked' : ''}><span class="toggle-track" aria-hidden="true"></span></label>`
      : `<input class="argument-input" type="text" data-argument-key="${escapeAttribute(argument.key)}" data-default="${escapeAttribute(argument.defaultValue)}" value="${escapeAttribute(argument.value)}" placeholder="${escapeAttribute(argument.defaultValue)}">`;
    return `<div class="detail-row argument-row"><div class="argument-name">${escapeHTML(argument.key)}</div><div class="argument-control">${control}</div></div>`;
  }

  function advancedGroupMarkup(group) {
    return `<details class="option-group" data-option-group="${escapeAttribute(group.id)}"><summary><span class="symbol" data-symbol="chevron.right"></span>${escapeHTML(group.title)}</summary><div class="option-content">${group.description ? `<p class="option-description">${escapeHTML(group.description)}</p>` : ''}${group.fields.map(optionFieldMarkup).join('')}</div></details>`;
  }

  function optionFieldMarkup(field) {
    if (field.type === 'heading') return `<div class="option-row"><strong>${escapeHTML(field.label)}</strong></div>`;
    if (field.type === 'toggle') return `<label class="option-row option-toggle"><span>${escapeHTML(field.label)}</span><input name="option_${escapeAttribute(field.key)}" type="checkbox" role="switch"><span class="toggle-track" aria-hidden="true"></span></label>`;
    const input = field.type === 'textarea'
      ? `<textarea name="option_${escapeAttribute(field.key)}" rows="2" placeholder="${escapeAttribute(field.prompt)}"></textarea>`
      : `<input name="option_${escapeAttribute(field.key)}" type="text" placeholder="${escapeAttribute(field.prompt)}">`;
    return `<div class="option-row"><label for="option_${escapeAttribute(field.key)}">${escapeHTML(field.label)}</label>${input}${field.help ? `<p class="option-help">${escapeHTML(field.help)}</p>` : ''}</div>`;
  }

  global.SurgeRelayWebMarkup = {
    detailRow,
    copyableValueSection,
    previewShell,
    publishFileList,
    latestPublishSection,
    argumentMarkup,
    advancedGroupMarkup,
    optionFieldMarkup
  };
})(globalThis);
