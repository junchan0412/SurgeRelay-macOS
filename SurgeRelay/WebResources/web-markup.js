(function installSurgeRelayWebMarkup(global) {
  const format = global.SurgeRelayWebFormat;
  if (!format) throw new Error('web-format.js must load before web-markup.js');
  const logic = global.SurgeRelayWebLogic;
  if (!logic) throw new Error('web-logic.js must load before web-markup.js');

  const { formatDate, escapeHTML, escapeAttribute } = format;

  function emptyStateMarkup(icon, message) {
    return `<div class="empty-state"><div><span class="symbol" data-symbol="${escapeAttribute(icon)}"></span><div>${escapeHTML(message)}</div></div></div>`;
  }

  function moduleRowMarkup(module, context = {}) {
    const combinedEnabled = Boolean(context.combinedEnabled);
    const selected = context.selectedID === module.id;
    const disabled = combinedEnabled && !module.isEnabled;
    const icon = module.iconURL
      ? `<img src="${escapeAttribute(module.iconURL)}" alt="" loading="lazy">`
      : '<span class="symbol" data-symbol="shippingbox"></span>';
    const stateClass = `state-${module.state || 'never'}`;
    const stateTitle = logic.moduleStatusTitle(module);
    const toggle = combinedEnabled
      ? `<label class="module-toggle" title="${module.isEnabled ? '从总模块中停用' : '包含在总模块中'}"><input type="checkbox" data-module-toggle="${escapeAttribute(module.id)}" ${module.isEnabled ? 'checked' : ''} aria-label="包含 ${escapeAttribute(module.name)}"><span class="toggle-track" aria-hidden="true"></span></label>`
      : '';
    return `<div class="module-row ${selected ? 'selected' : ''} ${disabled ? 'disabled' : ''}" data-id="${escapeAttribute(module.id)}" role="button" tabindex="0">
    <span class="module-icon ${module.iconURL ? '' : 'placeholder'}">${icon}</span>
    <span class="module-copy"><strong>${escapeHTML(module.name)}</strong><small>${escapeHTML(logic.moduleSubtitle(module))}</small></span>
    <span class="module-state-dot ${escapeAttribute(stateClass)}" title="${escapeAttribute(stateTitle)}"></span>
    ${toggle}
  </div>`;
  }

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

  function detailToolbar(selectedTab = 'info', hasModule = false) {
    return `<div class="detail-toolbar">
    <div class="segmented-control" aria-label="显示方式">
      <button data-action="tab-info" class="${selectedTab === 'info' ? 'selected' : ''}"><span class="symbol" data-symbol="info.circle"></span><span>详情</span></button>
      <button data-action="tab-preview" class="${selectedTab === 'preview' ? 'selected' : ''}"><span class="symbol" data-symbol="curlybraces"></span><span>预览</span></button>
    </div>
    ${hasModule ? `<button class="button" data-action="edit"><span class="symbol" data-symbol="pencil"></span>编辑</button><button class="button destructive" data-action="delete"><span class="symbol" data-symbol="trash"></span>删除</button>` : ''}
  </div>`;
  }

  function combinedDetailMarkup(combined, context = {}) {
    const selectedTab = context.selectedTab || 'info';
    if (!combined?.isEnabled) {
      return `<div class="empty-state"><div><span class="symbol" data-symbol="square.stack.3d.up"></span><div>总模块功能未开启</div></div></div>`;
    }
    if (selectedTab === 'preview') {
      return detailToolbar(selectedTab) + previewShell(combined.fileName, false);
    }
    const subscription = copyableValueSection('总模块订阅地址', combined.subscriptionURL);
    const latestPublish = latestPublishSection(context.latestGitHubPublish);
    return `${detailToolbar(selectedTab)}
    <section class="form-section-view"><h3 class="section-heading">汇总模块</h3><div class="group-box">
      ${detailRow('square.stack.3d.up.fill', '名称', combined.name)}
      ${detailRow('shippingbox', '包含来源', `${combined.enabledCount} / ${combined.sourceCount}`)}
      ${detailRow('clock', '最新更新', formatDate(combined.lastUpdatedAt, '尚未更新'))}
    </div></section>${subscription}${latestPublish}`;
  }

  function moduleDetailMarkup(module, context = {}) {
    const selectedTab = context.selectedTab || 'info';
    if (selectedTab === 'preview') {
      return detailToolbar(selectedTab, true) + previewShell(module.publishedRelativePath || module.outputFileName, true);
    }
    const combined = context.combined || {};
    const advanced = module.advancedSummary ? `<section class="form-section-view"><h3 class="section-heading">高级设置</h3><div class="group-box"><div class="detail-row"><div class="detail-label"><span class="symbol" data-symbol="slider.horizontal.3"></span><span>已应用</span></div><div class="detail-value advanced-summary">${escapeHTML(module.advancedSummary)}</div></div></div></section>` : '';
    const publishedTitle = module.publishedURL?.includes('workers.dev') ? 'Cloudflare' : 'GitHub';
    const published = copyableValueSection(publishedTitle, module.publishedURL);
    const errorNote = combined.isEnabled ? '如果该来源有缓存，总模块会继续沿用它上一次成功版本。' : '如果该来源有缓存，模块输出会继续沿用它上一次成功版本。';
    const errorBody = module.lastError ? escapeHTML(module.lastError).replace(/\n/g, '<br>') : '';
    const errorActions = module.lastError ? `<div><button class="button" data-action="copy" data-value="${escapeAttribute(module.lastError)}"><span class="symbol" data-symbol="copy"></span>复制错误</button></div>` : '';
    const error = module.lastError ? `<section class="form-section-view"><h3 class="section-heading">最近一次更新失败</h3><div class="group-box"><div class="detail-row action-row error-box"><strong>${escapeHTML(logic.moduleStatusTitle(module))}</strong><div>${errorBody}</div><small>${escapeHTML(errorNote)}</small>${errorActions}</div></div></section>` : '';
    const conflict = module.hasOverrideConflict ? `<section class="form-section-view"><h3 class="section-heading">本地编辑冲突</h3><div class="group-box"><div class="detail-row action-row error-box"><strong>上游内容已经变化</strong><div>当前仍在使用本地编辑。可在预览中比较内容后保留或恢复。</div><div><button class="button" data-action="accept-override">保留本地编辑</button><button class="button" data-action="tab-preview">前往预览</button></div></div></div></section>` : '';
    const combinedSubscription = combined.subscriptionURL || '';
    const combinedRow = combined.isEnabled ? detailRow('square.stack.3d.up.fill', '汇总订阅', combinedSubscription || '等待发布配置', false, combinedSubscription || null) : '';
    const iconURL = module.customIconURL || module.iconURL;
    const iconSource = module.customIconURL ? '自定义图标（仅展示）' : (module.iconURL ? '来源元数据（仅展示）' : '默认图标');
    const iconAddressRow = iconURL ? detailRow('link', '图标地址', `<a href="${escapeAttribute(iconURL)}" target="_blank" rel="noreferrer">${escapeHTML(iconURL)}</a>`, true, iconURL) : '';
    const sourceHashRow = module.sourceContentHash ? detailRow('curlybraces', '来源 hash', module.sourceContentHash.slice(0, 12), false, module.sourceContentHash) : '';
    const sourceETagRow = module.sourceETag ? detailRow('tag', '来源 ETag', module.sourceETag, false, module.sourceETag) : '';
    const sourceLastModifiedRow = module.sourceLastModified ? detailRow('clock', '来源修改时间', module.sourceLastModified) : '';
    const outputPath = module.publishesStandalone ? (module.publishedRelativePath || module.outputFileName) : '';
    const sourceAddress = module.effectiveOriginalSourceURL || module.sourceURL || '';
    const sourceAddressValue = /^https?:\/\//i.test(sourceAddress)
      ? `<a href="${escapeAttribute(sourceAddress)}" target="_blank" rel="noreferrer">${escapeHTML(sourceAddress)}</a>`
      : escapeHTML(sourceAddress);
    const sourceRecordRow = module.sourceURL && module.sourceURL !== sourceAddress
      ? detailRow('link', '来源记录', escapeHTML(module.sourceURL), true, module.sourceURL)
      : '';
    const localStorageRow = module.localStorageRelativePath
      ? detailRow('folder', '本地相对路径', module.localStorageRelativePath, false, module.localStorageRelativePath)
      : '';
    return `${detailToolbar(selectedTab, true)}
    ${error}
    <section class="form-section-view"><h3 class="section-heading">管理关系</h3><div class="group-box">
      ${detailRow(module.storageLocationIcon || 'folder', '模块存放', module.storageLocationTitle || 'GitHub 模块')}
      ${detailRow(module.sourceOriginIcon || 'link', '转换前来源', module.sourceOriginTitle || module.sourceFormatTitle)}
      ${detailRow('link', '原始地址', sourceAddressValue, true, sourceAddress)}
      ${sourceRecordRow}
      ${detailRow('doc.text', '来源格式', module.sourceFormatTitle)}
      ${detailRow('tag', '模块标签', module.category || '未设置')}
      ${detailRow('folder', '存放文件夹', logic.folderTitle(module.outputFolder))}
      ${localStorageRow}
      ${detailRow('doc.on.doc', '输出文件', outputPath || '未开启独立发布', false, outputPath || null)}
      ${detailRow('info.circle', '图标来源', iconSource)}
      ${iconAddressRow}
      ${detailRow('doc.text', '独立模块', module.publishesStandalone ? '发布' : '不发布')}
      ${combinedRow}
      ${detailRow('checkmark', '更新状态', logic.moduleStatusTitle(module))}
      ${detailRow('clock', '创建时间', formatDate(module.createdAt, '—'))}
      ${detailRow('clock', '上次更新', formatDate(module.lastUpdatedAt, '从未更新'))}
      ${detailRow('refresh', '来源检查', formatDate(module.sourceCheckedAt, '尚未检查'))}
      ${detailRow('curlybraces', '内容 hash', module.contentHash ? module.contentHash.slice(0, 12) : '尚未生成', false, module.contentHash || null)}
      ${sourceHashRow}
      ${sourceETagRow}
      ${sourceLastModifiedRow}
      ${detailRow('gearshape', '转换引擎', module.conversionEngineRevision ? module.conversionEngineRevision.slice(0, 12) : '原生 Surge 模块', false, module.conversionEngineRevision || null)}
    </div></section>
    ${advanced}<div id="arguments-section"></div>${conflict}${published}`;
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
    emptyStateMarkup,
    moduleRowMarkup,
    detailRow,
    copyableValueSection,
    previewShell,
    publishFileList,
    latestPublishSection,
    detailToolbar,
    combinedDetailMarkup,
    moduleDetailMarkup,
    argumentMarkup,
    advancedGroupMarkup,
    optionFieldMarkup
  };
})(globalThis);
