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
    return `<div class="module-row ${selected ? 'selected' : ''} ${disabled ? 'disabled' : ''}" data-id="${escapeAttribute(module.id)}">
    <button class="module-open" type="button" aria-current="${selected ? 'page' : 'false'}" aria-label="${escapeAttribute(module.name)}，${escapeAttribute(stateTitle)}">
    <span class="module-icon ${module.iconURL ? '' : 'placeholder'}">${icon}</span>
    <span class="module-copy"><strong>${escapeHTML(module.name)}</strong><small>${escapeHTML(logic.moduleSubtitle(module))}</small></span>
    <span class="module-state-dot ${escapeAttribute(stateClass)}" title="${escapeAttribute(stateTitle)}" aria-hidden="true"></span>
    </button>
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
    return `<section class="preview-shell" id="detail-panel" role="tabpanel" aria-labelledby="detail-tab-preview"><div class="preview-toolbar"><div class="preview-caption"><span class="preview-label" title="${escapeAttribute(label)}">${escapeHTML(label)}</span><span id="preview-status" class="preview-status" role="status" aria-live="polite" aria-atomic="true" data-state="loading">正在载入</span></div><div class="preview-actions"><button class="button" data-action="copy-preview" disabled><span class="symbol" data-symbol="doc.on.doc"></span>拷贝全部</button>${editable ? `<button class="button" data-action="restore-preview" title="丢弃本地编辑并恢复转换结果" disabled><span class="symbol" data-symbol="arrow.uturn.backward"></span>恢复</button><button class="button" data-action="compare-preview" hidden>查看服务器版本</button><button class="button" data-action="recover-draft" hidden>恢复草稿</button><button class="button" data-action="discard-draft" hidden>删除草稿</button><button class="button primary" data-action="save-preview" aria-keyshortcuts="Meta+s Control+s" title="写入修改（⌘/Ctrl+S）" disabled>写入</button>` : ''}<button class="button" data-action="retry-preview" hidden><span class="symbol" data-symbol="arrow.clockwise"></span>重试</button></div></div><p class="preview-message" id="preview-message" role="alert" hidden></p>${editable ? '<pre id="server-preview" class="code-view" tabindex="0" aria-label="当前服务器版本，仅供比较" hidden></pre><textarea class="code-editor" id="code-editor" spellcheck="false" autocapitalize="off" autocomplete="off" autocorrect="off" aria-label="模块内容" disabled>正在载入…</textarea>' : '<pre class="code-view" id="code-view" tabindex="0" aria-label="总模块内容">正在载入…</pre>'}</section>`;
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
    <div class="segmented-control" role="tablist" aria-label="显示方式">
      <button data-action="tab-info" class="${selectedTab === 'info' ? 'selected' : ''}" id="detail-tab-info" role="tab" aria-controls="detail-panel" tabindex="${selectedTab === 'info' ? '0' : '-1'}" aria-selected="${selectedTab === 'info'}"><span class="symbol" data-symbol="info.circle"></span><span>详情</span></button>
      <button data-action="tab-preview" class="${selectedTab === 'preview' ? 'selected' : ''}" id="detail-tab-preview" role="tab" aria-controls="detail-panel" tabindex="${selectedTab === 'preview' ? '0' : '-1'}" aria-selected="${selectedTab === 'preview'}"><span class="symbol" data-symbol="curlybraces"></span><span>预览</span></button>
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
    return `${detailToolbar(selectedTab)}<div id="detail-panel" role="tabpanel" aria-labelledby="detail-tab-info">
    <section class="form-section-view"><h3 class="section-heading">汇总模块</h3><div class="group-box">
      ${detailRow('square.stack.3d.up.fill', '名称', combined.name)}
      ${detailRow('shippingbox', '包含来源', `${combined.enabledCount} / ${combined.sourceCount}`)}
      ${detailRow('clock', '最新更新', formatDate(combined.lastUpdatedAt, '尚未更新'))}
    </div></section>${subscription}${latestPublish}</div>`;
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
    const syncConflict = module.hasSyncConflict ? `<section class="form-section-view"><h3 class="section-heading">本地与 GitHub 内容冲突</h3><div class="group-box"><div class="detail-row action-row error-box"><strong>检测到两端输出内容不同</strong><div>本地最后更新：${escapeHTML(formatDate(module.syncConflictLocalUpdatedAt, '未知'))}</div><div>GitHub 最后更新：${escapeHTML(formatDate(module.syncConflictGitHubUpdatedAt, '未知'))}</div><button class="button" data-action="compare-sync">比较两端并处理</button></div></div></section>` : '';
    const combinedSubscription = combined.subscriptionURL || '';
    const combinedRow = combined.isEnabled ? detailRow('square.stack.3d.up.fill', '汇总订阅', combinedSubscription || '等待发布配置', false, combinedSubscription || null) : '';
    const iconURL = module.customIconURL || module.iconURL;
    const iconSource = module.customIconURL ? '自定义图标（写入输出）' : (module.iconURL ? '来源图标' : '默认图标');
    const iconAddressRow = iconURL ? detailRow('link', '图标地址', `<a href="${escapeAttribute(iconURL)}" target="_blank" rel="noreferrer">${escapeHTML(iconURL)}</a>`, true, iconURL) : '';
    const sourceHashRow = module.sourceContentHash ? detailRow('curlybraces', '来源 hash', module.sourceContentHash.slice(0, 12), false, module.sourceContentHash) : '';
    const sourceETagRow = module.sourceETag ? detailRow('tag', '来源 ETag', module.sourceETag, false, module.sourceETag) : '';
    const sourceLastModifiedRow = module.sourceLastModified ? detailRow('clock', '来源修改时间', module.sourceLastModified) : '';
    const outputPath = module.publishesStandalone ? (module.publishedRelativePath || module.outputFileName) : '';
    const initialSourceAddress = module.initialSourceURL || '';
    const configuredSourceAddress = module.sourceURL || '';
    const updateSourceAddress = module.updateSourceURL || configuredSourceAddress;
    const addressMarkup = value => /^https?:\/\//i.test(value)
      ? `<a href="${escapeAttribute(value)}" target="_blank" rel="noreferrer">${escapeHTML(value)}</a>`
      : escapeHTML(value);
    const initialSourceRow = initialSourceAddress
      ? detailRow('link', '订阅原始地址', addressMarkup(initialSourceAddress), true, initialSourceAddress)
      : '';
    const updateSourceRow = !initialSourceAddress
      ? detailRow('link', '更新地址', addressMarkup(updateSourceAddress), true, updateSourceAddress)
      : '';
    const registeredSourceRow = initialSourceAddress && configuredSourceAddress && configuredSourceAddress !== initialSourceAddress
      ? detailRow('link', '登记地址', addressMarkup(configuredSourceAddress), true, configuredSourceAddress)
      : '';
    const localStorageRow = module.localStorageRelativePath
      ? detailRow('folder', '本地相对路径', module.localStorageRelativePath, false, module.localStorageRelativePath)
      : '';
    return `${moduleHeaderMarkup(module, context.activity)}${detailToolbar(selectedTab, true)}<div id="detail-panel" role="tabpanel" aria-labelledby="detail-tab-info">
    ${error}${conflict}${syncConflict}
    <section class="form-section-view"><h3 class="section-heading">管理关系</h3><div class="group-box">
      ${updateSourceRow || initialSourceRow}
      ${detailRow('doc.on.doc', '输出路径', outputPath || '未开启独立发布', false, outputPath || null)}
      ${detailRow('clock', '上次更新', formatDate(module.lastUpdatedAt, '从未更新'))}
      ${detailRow('clock.arrow.circlepath', '刷新策略', logic.refreshIntervalTitle(module.refreshIntervalMinutes))}
      ${detailRow('clock', '下次重试', formatDate(module.nextRetryAt, '未安排'))}
      ${detailRow('hourglass', '服务器冷却', logic.serverCooldownRemaining(module) > 0 ? `${formatDate(module.serverRetryAfter)} 前不可手动更新` : '无（或已结束）')}
      ${detailRow('exclamationmark.triangle', '连续失败', `${Number(module.consecutiveFailureCount || 0)} 次${module.consecutiveFailureCount > 0 ? '；手动更新可跳过普通退避' : ''}`)}
      <details class="metadata-details"><summary>来源与同步详情<span class="symbol" data-symbol="chevron.right"></span></summary>
      ${detailRow(module.publishesStandalone ? (module.storageLocationIcon || 'folder') : 'folder', '独立模块存放', module.storageLocationDetail || module.storageLocationTitle || '未开启独立发布')}
      ${detailRow(module.initialSourceIcon || 'link', '初始来源', module.initialSourceTitle || '自写模块')}
      ${initialSourceRow}
      ${updateSourceRow}
      ${registeredSourceRow}
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
      </details>
    </div></section>
    <div id="arguments-section"></div>${published}${advanced}</div>`;
  }

  function argumentMarkup(argument) {
    const isBoolean = ['true', 'false'].includes(String(argument.defaultValue).toLowerCase());
    const control = isBoolean
      ? `<label class="module-toggle argument-toggle"><input type="checkbox" data-argument-key="${escapeAttribute(argument.key)}" data-default="${escapeAttribute(argument.defaultValue)}" ${String(argument.value).toLowerCase() === 'true' ? 'checked' : ''}><span class="toggle-track" aria-hidden="true"></span></label>`
      : `<input class="argument-input" type="text" data-argument-key="${escapeAttribute(argument.key)}" data-default="${escapeAttribute(argument.defaultValue)}" value="${escapeAttribute(argument.value)}" placeholder="${escapeAttribute(argument.defaultValue)}">`;
    return `<div class="detail-row argument-row"><div class="argument-name">${escapeHTML(argument.key)}</div><div class="argument-control">${control}</div></div>`;
  }

  function argumentsSectionMarkup(payload) {
    const argumentsList = payload?.arguments || [];
    if (!argumentsList.length) return '';
    const resetDisabled = argumentsList.every(item => item.value === item.defaultValue);
    const help = payload.help
      ? `<details class="parameter-help"><summary><span class="symbol" data-symbol="chevron.right"></span>参数说明</summary><p>${escapeHTML(payload.help)}</p></details>`
      : '';
    return `<section class="form-section-view page-enter"><h3 class="section-heading">模块参数</h3><div class="group-box">
      ${argumentsList.map(argumentMarkup).join('')}
      <div class="arguments-footer"><small>修改会立即应用</small><button class="button" data-action="reset-arguments" ${resetDisabled ? 'disabled' : ''}>恢复默认值</button></div>
      ${help}
    </div></section>`;
  }

  function advancedGroupMarkup(group) {
    return `<details class="option-group" data-option-group="${escapeAttribute(group.id)}"><summary><span class="symbol" data-symbol="chevron.right"></span>${escapeHTML(group.title)}</summary><div class="option-content">${group.description ? `<p class="option-description">${escapeHTML(group.description)}</p>` : ''}${group.fields.map(optionFieldMarkup).join('')}</div></details>`;
  }

  function advancedOptionsMarkup(groups = []) {
    return `<p class="advanced-intro">这些选项由 App 内置的 Script‑Hub 引擎执行，并随当前模块保存。留空即采用上游默认行为。</p>${groups.map(advancedGroupMarkup).join('')}`;
  }

  function optionFieldMarkup(field) {
    if (field.type === 'heading') return `<div class="option-row"><strong>${escapeHTML(field.label)}</strong></div>`;
    if (field.type === 'toggle') return `<label class="option-row option-toggle"><span>${escapeHTML(field.label)}</span><input name="option_${escapeAttribute(field.key)}" type="checkbox" role="switch"><span class="toggle-track" aria-hidden="true"></span></label>`;
    const input = field.type === 'textarea'
      ? `<textarea name="option_${escapeAttribute(field.key)}" rows="2" placeholder="${escapeAttribute(field.prompt)}"></textarea>`
      : `<input name="option_${escapeAttribute(field.key)}" type="text" placeholder="${escapeAttribute(field.prompt)}">`;
    return `<div class="option-row"><label for="option_${escapeAttribute(field.key)}">${escapeHTML(field.label)}</label>${input}${field.help ? `<p class="option-help">${escapeHTML(field.help)}</p>` : ''}</div>`;
  }

  function outputFolderOptionsMarkup(folders = [], selected = '') {
    const values = new Set(['', ...(folders || []), selected || '']);
    return [...values].sort((a, b) => {
      if (!a) return -1;
      if (!b) return 1;
      return a.localeCompare(b, 'zh-Hans-CN', { numeric: true });
    }).map(folder => `<option value="${escapeAttribute(folder)}">${escapeHTML(logic.folderTitle(folder))}</option>`).join('');
  }

  function stageMetricsMarkup(metrics) {
    if (!Array.isArray(metrics) || !metrics.length) return '';
    const rows = metrics.slice(0, 4).map(metric => {
      const item = format.stageMetricPresentation(metric);
      return `<tr><th scope="row">${escapeHTML(item.stage)}${item.partial ? `<small>${escapeHTML(item.partial)}</small>` : ''}</th><td>${escapeHTML(item.duration)}</td><td>${escapeHTML(item.read)}</td><td>${escapeHTML(item.written)}</td><td>${escapeHTML(item.attempts)} / ${escapeHTML(item.failedAttempts)}</td><td>${escapeHTML(item.result)}${item.reason ? `<small>${escapeHTML(item.reason)}</small>` : ''}</td></tr>`;
    }).join('');
    return `<details class="stage-metrics"><summary>性能明细（${Math.min(metrics.length, 4)} 个阶段）</summary><p>阶段可能并行，不可相加作为总耗时。下列字节为内容字节，不代表 TLS 流量或物理 I/O。</p><div class="stage-metrics-table"><table><thead><tr><th>阶段</th><th>耗时</th><th>读取内容字节</th><th>写入内容字节</th><th>尝试 / 失败</th><th>结果</th></tr></thead><tbody>${rows}</tbody></table></div></details>`;
  }

  function historyMarkup(entries = [], options = {}) {
    const outcomes = { updated: ['已更新', 'success'], unchanged: ['没有变化', 'neutral'], cachedAfterFailure: ['沿用缓存', 'warning'], failed: ['更新失败', 'error'], published: ['已发布', 'success'] };
    if (!entries.length) return '<div class="workspace-empty"><span class="symbol" data-symbol="clock"></span><p>更新模块或发布后，操作记录会出现在这里。</p></div>';
    return `<div class="history-list">${entries.map((entry, historyIndex) => {
      const [title, tone] = outcomes[entry.outcome] || [entry.outcome || '活动', 'neutral'];
      const id = String(entry.moduleID || '').toLowerCase();
      const moduleLink = id ? `<button class="text-button" data-action="show-module" data-id="${escapeAttribute(id)}">查看模块<span class="symbol" data-symbol="chevron.right"></span></button>` : '';
      return `<article class="history-item"><span class="history-marker ${tone}"><span class="symbol" data-symbol="${tone === 'error' || tone === 'warning' ? 'exclamationmark.triangle' : entry.outcome === 'published' ? 'square.and.arrow.up' : 'checkmark'}"></span></span><div class="history-copy"><div class="history-title"><strong>${escapeHTML(entry.moduleName || 'Surge Relay')}</strong><span class="status-label ${tone}">${escapeHTML(title)}</span><time>${escapeHTML(formatDate(entry.date, '—'))}</time></div><p>${escapeHTML(entry.message || '')}</p>${options.detailed ? `<div class="history-meta"><span>耗时 ${Number(entry.duration || 0).toFixed(2)} 秒</span>${moduleLink}<button class="text-button" data-action="copy-history" data-history-index="${historyIndex}">复制记录</button></div>${stageMetricsMarkup(entry.stageMetrics)}` : ''}</div></article>`;
    }).join('')}</div>`;
  }

  function workspaceMarkup(snapshot) {
    const modules = snapshot.modules || [];
    const attention = modules.filter(module => module.state === 'failed' || module.hasOverrideConflict || module.hasSyncConflict);
    const standalone = modules.filter(module => module.publishesStandalone).length;
    const workspace = snapshot.workspace || {};
    const targets = snapshot.moduleEditor || {};
    const metric = (label, value, action = '', tone = '') => `<${action ? 'button' : 'div'} class="workspace-metric ${tone}" ${action ? `data-action="${action}"` : ''}><span>${label}</span><strong>${value}</strong></${action ? 'button' : 'div'}>`;
    const issueRows = attention.slice(0, 3).map(module => `<button class="attention-item" data-action="show-module" data-id="${escapeAttribute(module.id)}"><span class="symbol" data-symbol="exclamationmark.triangle"></span><span><strong>${escapeHTML(module.name)}</strong><small>${escapeHTML(module.lastError ? logic.failureSummary(module.lastError) : '本地内容与更新版本存在冲突')}</small></span><span class="symbol" data-symbol="chevron.right"></span></button>`).join('');
    const normal = `<div class="workspace-healthy"><span class="symbol" data-symbol="checkmark"></span><div><strong>没有需要处理的问题</strong><p>更新失败和内容冲突会集中显示在这里。</p></div><button class="button" data-action="update-all" ${snapshot.activity?.canStartUpdate === false ? 'disabled' : ''}>检查更新</button></div>`;
    const onboarding = '<div class="workspace-empty"><span class="symbol" data-symbol="square.stack.3d.up"></span><h2>把第一个模块交给 Relay</h2><p>添加 Surge、Loon 或 Quantumult X 来源，维护转换结果与稳定订阅地址。</p><button class="button primary" data-action="add-module">添加来源</button></div>';
    const target = (title, icon, enabled, detail, note) => `<article class="destination-card"><div><span class="symbol" data-symbol="${icon}"></span><h3>${title}</h3><span class="status-label ${enabled ? 'success' : 'neutral'}">${enabled ? '已开启' : '未开启'}</span></div><strong title="${escapeAttribute(detail)}">${escapeHTML(detail)}</strong><p>${escapeHTML(note)}</p></article>`;
    return `<div class="workspace-heading"><div class="eyebrow">SURGE RELAY</div><div class="workspace-heading-line"><div><h1>模块工作台</h1><p>从来源更新到稳定发布，每一步都在这里。</p></div><button class="button primary" data-action="add-module"><span class="symbol" data-symbol="plus"></span>添加模块</button></div></div>
      <section class="workspace-metrics" aria-label="模块概况">${metric('模块总数', modules.length)}${metric('可更新', snapshot.activity?.enabledModuleCount ?? modules.length)}${metric('独立发布', standalone)}${metric('需要处理', attention.length, 'show-attention', attention.length ? 'warning' : '')}</section>
      <section class="workspace-section"><div class="workspace-section-heading"><h2>运行状态</h2>${attention.length ? '<button class="text-button" data-action="show-attention">查看全部</button>' : ''}</div><div class="workspace-panel">${!modules.length ? onboarding : attention.length ? issueRows : normal}</div></section>
      <section class="workspace-section"><div class="workspace-section-heading"><h2>发布去向</h2><span>在 Mac App 的设置中管理</span></div><div class="operation-buttons"><button class="button" data-action="publish-selected">发布所选模块</button><button class="button" data-action="publish-github" ${targets.publishToGitHub ? '' : 'disabled'}>预览发布到 GitHub</button><button class="button" data-action="publish-results">上次发布结果</button></div><div class="destination-grid">${target('本地目录', 'externaldrive', targets.publishToLocal, workspace.localDirectory || '选择 Surge 模块目录', `${modules.filter(m => (m.storageTargets || [m.storageLocation]).includes('local')).length} 个模块存放在本地`)}${target('GitHub', 'network', targets.publishToGitHub, workspace.githubRepository || '连接仓库以分发模块', workspace.githubBranch ? `分支 ${workspace.githubBranch}` : '配置仓库后可自动发布更新')}</div></section>
      <section class="workspace-section"><div class="workspace-section-heading"><h2>最近活动</h2><button class="text-button" data-action="show-activity">全部记录<span class="symbol" data-symbol="chevron.right"></span></button></div><div class="workspace-panel">${historyMarkup(workspace.recentHistory || [])}</div></section>`;
  }

  function publicationSelectionMarkup(modules, selectedIDs) {
    const eligible = modules.filter(module => module.publishesStandalone);
    return `<p>选择要发布的独立模块。预览会按每个模块的存放目标计算文件变更；此步骤不会发布。</p><div class="operation-buttons"><button class="button" data-operation="select-all">全选</button><button class="button" data-operation="select-none">清空选择</button><button class="button" data-operation="last-result">上次发布结果</button></div><fieldset class="publication-selection"><legend>独立模块（${eligible.length}）</legend>${eligible.map(module => `<label><input type="checkbox" data-publish-module="${escapeAttribute(module.id)}" ${selectedIDs.has(module.id) ? 'checked' : ''}><span>${escapeHTML(module.name)}<small>${escapeHTML(module.storageLocationTitle || '')}</small></span></label>`).join('') || '<p>没有开启独立发布的模块。</p>'}</fieldset><div class="operation-buttons"><button class="button primary" data-operation="preview-selected" ${selectedIDs.size ? '' : 'disabled'}>预览所选发布</button></div>`;
  }

  function publicationPreviewMarkup(plan) {
    const previews = plan.previews || [];
    const hasWarnings = previews.some(preview => (preview.issues || []).some(issue => issue.severity === 'warning'));
    return `<p>请核对下面的目标与文件清单。确认后仅执行本次预览；内容或配置变化时需要重新预览。</p>${previews.map(preview => `<section class="operation-target"><h3>${preview.destination === 'local' ? '本地' : 'GitHub'}</h3><p>${escapeHTML(preview.targetDescription || '')}</p><p>有效文件 ${(preview.activeFiles || []).length} 个</p>${preview.issues?.length ? `<section aria-label="发布校验提示"><h4>发布前提示</h4><ul>${preview.issues.map(issue => `<li><strong><code>${escapeHTML(issue.filePath)}:${escapeHTML(issue.line)}</code></strong> ${escapeHTML(issue.message)}${issue.relatedLine != null ? `（相关行 ${escapeHTML(issue.relatedLine)}）` : ''}</li>`).join('')}</ul></section>` : ''}${publishFileList('新增或更新', preview.changedFiles || [])}${publishFileList('删除', preview.deletedFiles || [], true)}${!(preview.changedFiles?.length || preview.deletedFiles?.length) ? '<p>没有文件变化。</p>' : ''}</section>`).join('') || '<p>没有可发布的目标。</p>'}<div class="operation-buttons"><button class="button" data-operation="refresh-preview">重新预览</button><button class="button primary" data-operation="execute-publish" ${previews.some(preview => preview.changedFiles?.length || preview.deletedFiles?.length) ? '' : 'disabled'}>${hasWarnings ? '确认并继续发布以上变更' : '确认发布以上变更'}</button></div>`;
  }

  function publicationResultMarkup(attempt, message = '') {
    const labels = { pending: '未完成', succeeded: '成功', failed: '失败', cancelled: '已取消', skipped: '已跳过' };
    const retryable = (attempt?.results || []).some(result => ['pending', 'failed', 'cancelled'].includes(result.status));
    return `${message ? `<p role="status">${escapeHTML(message)}</p>` : ''}${(attempt?.results || []).map(result => `<section class="operation-target"><h3>${result.destination === 'local' ? '本地' : 'GitHub'} · ${labels[result.status] || '未知状态'}</h3><p>${escapeHTML(result.target || '')}</p><p>${escapeHTML(result.message || '')}</p>${publishFileList('已发布', result.publishedFiles || [])}${result.commitSHA ? `<p>Commit <code>${escapeHTML(result.commitSHA)}</code></p>` : ''}</section>`).join('') || (message ? '' : '<p>没有可恢复的所选发布记录。</p>')}<div class="operation-buttons">${retryable ? '<button class="button primary" data-operation="retry-publish">仅预览重试未完成目标</button>' : ''}<button class="button" data-operation="choose-modules">重新选择模块</button></div>`;
  }

  function lineDiffMarkup(diff, leftTitle, rightTitle, caption) {
    const rows = (diff.rows || []).map(row => `<tr class="diff-${['added', 'removed'].includes(row.kind) ? row.kind : 'context'}"><td>${escapeHTML(row.localLine ?? '')}</td><td>${escapeHTML(row.githubLine ?? '')}</td><td><code>${row.kind === 'added' ? '+' : row.kind === 'removed' ? '−' : ' '} ${escapeHTML(row.text || '')}</code></td></tr>`).join('');
    return `<div class="sync-diff"><table><caption>${escapeHTML(caption)}</caption><thead><tr><th>${escapeHTML(leftTitle)}</th><th>${escapeHTML(rightTitle)}</th><th>内容</th></tr></thead><tbody>${rows}</tbody></table></div>`;
  }

  function synchronizationMarkup(comparison) {
    const diff = comparison.diff || {};
    return `<p><strong>${escapeHTML(comparison.stateTitle || '两端比较')}</strong></p><p>删除 ${diff.removedCount || 0} 行，新增 ${diff.addedCount || 0} 行。− 表示本地独有，+ 表示 GitHub 独有。</p>${diff.isTruncated || diff.usesCoarseComparison ? '<p role="status">差异已简化或截断，请展开下面的完整正文核对后再覆盖。</p>' : ''}${lineDiffMarkup(diff, '本地行', 'GitHub 行', '本地 → GitHub 内容差异')}<div class="sync-sources"><details><summary>本地完整正文</summary><pre>${escapeHTML(comparison.localContent || '')}</pre></details><details><summary>GitHub 完整正文</summary><pre>${escapeHTML(comparison.gitHubContent || '')}</pre></details></div><div class="operation-buttons"><button class="button" data-operation="refresh-sync">重新比较</button><button class="button destructive" data-operation="local-to-github" ${comparison.state === 'same' ? 'disabled' : ''}>用本地覆盖 GitHub</button><button class="button destructive" data-operation="github-to-local" ${comparison.state === 'same' ? 'disabled' : ''}>用 GitHub 覆盖本地</button></div>`;
  }

  function versionHistoryMarkup(versions) {
    const reasons = { current: '当前缓存', beforeUpdate: '更新前', beforeEdit: '编辑前', manualEdit: '已保存编辑', beforeRestore: '恢复前', restored: '已恢复版本' };
    return `<p>选择版本查看差异。本次恢复缓存并暂停该模块自动刷新，不立即发布；后续发布仍按现有发布设置执行。未保存的浏览器草稿会保留。</p>${versions.map(version => `<section class="operation-target"><h3>${escapeHTML(formatDate(version.createdAt, '未知时间'))} · ${escapeHTML(reasons[version.reason] || version.reason || '历史版本')}</h3><p>${Number(version.byteCount || 0).toLocaleString()} 字节 · ${(version.assets || []).length} 个资源 · ${version.hasOverride ? '包含手动编辑' : '转换缓存'}</p><p>内容 hash <code>${escapeHTML(version.contentHash || '')}</code></p><button class="button" data-operation="compare-version" data-version-id="${escapeAttribute(version.id)}">与当前缓存比较</button></section>`).join('') || '<p>暂无可用的历史版本。</p>'}<div class="operation-buttons"><button class="button" data-operation="version-list">刷新历史列表</button></div>`;
  }

  function versionComparisonMarkup(comparison) {
    const diff = comparison.diff || {};
    const version = comparison.version || {};
    return `<p><strong>历史版本 → 当前缓存</strong></p><p>选中版本：${escapeHTML(formatDate(version.createdAt, '未知时间'))}。下表展示历史到当前的变化，恢复将执行反向变化。</p><p>−${diff.removedCount || 0} 行 · +${diff.addedCount || 0} 行 · ${(comparison.changedAssets || []).length} 个资源变化</p>${diff.isTruncated || diff.usesCoarseComparison ? '<p role="status">变化较大，差异已简化或截断；请谨慎核对后恢复。</p>' : ''}${diff.hasFinalNewlineDifference ? '<p>文件末尾换行不同。</p>' : ''}${lineDiffMarkup(diff, '历史行', '当前行', '历史版本 → 当前缓存')}${publishFileList('资源变化（+ 当前新增，− 当前缺少，~ 内容变化）', comparison.changedAssets || [])}<details><summary>历史版本资源清单</summary>${(version.assets || []).map(asset => `<p><code>${escapeHTML(asset.path)}</code> · ${Number(asset.byteCount || 0).toLocaleString()} 字节<br><code>${escapeHTML(asset.contentHash)}</code></p>`).join('') || '<p>无附带资源。</p>'}</details><p>本次仅恢复缓存并暂停该模块自动刷新，不立即发布；后续发布仍按现有发布设置执行。浏览器草稿保留；之后可另点“发布此模块”。</p><div class="operation-buttons"><button class="button" data-operation="version-list">返回历史列表</button><button class="button" data-operation="refresh-version">重新比较</button><button class="button destructive" data-operation="restore-version">恢复到缓存并暂停自动刷新</button></div>`;
  }

  function moduleHeaderMarkup(module, activity = {}) {
    const cooling = logic.serverCooldownRemaining(module) > 0;
    const icon = module.iconURL ? `<img src="${escapeAttribute(module.iconURL)}" alt="">` : '<span class="symbol" data-symbol="shippingbox"></span>';
    return `<header class="module-heading"><div class="module-heading-title"><span class="module-hero-icon">${icon}</span><div><p class="eyebrow">${escapeHTML(module.initialSourceTitle || '模块来源')}</p><h1>${escapeHTML(module.name)}</h1><p>${escapeHTML(module.category || module.sourceFormatTitle || 'Surge 模块')}</p></div></div><div class="module-heading-meta"><span class="status-label ${module.state === 'failed' ? 'error' : module.state === 'current' ? 'success' : 'neutral'}">${escapeHTML(logic.moduleStatusTitle(module))}</span><span>更新于 ${escapeHTML(formatDate(module.lastUpdatedAt, '尚未更新'))}</span><button class="button" data-action="version-history">版本历史</button>${module.publishesStandalone ? '<button class="button" data-action="publish-selected">发布此模块</button>' : ''}${(module.storageTargets || []).length > 1 && !module.hasSyncConflict ? '<button class="button" data-action="compare-sync">比较两端</button>' : ''}<button class="button primary" data-action="update-module" title="${escapeAttribute(cooling ? `服务器冷却至 ${formatDate(module.serverRetryAfter)}，手动更新也需等待` : '更新模块')}" ${activity.isWorking || cooling ? 'disabled' : ''}><span class="symbol" data-symbol="refresh"></span>${cooling ? '服务器冷却中' : '更新模块'}</button></div></header>`;
  }

  global.SurgeRelayWebMarkup = {
    publicationSelectionMarkup, publicationPreviewMarkup, publicationResultMarkup, synchronizationMarkup, versionHistoryMarkup, versionComparisonMarkup,
    emptyStateMarkup,
    workspaceMarkup,
    stageMetricsMarkup, historyMarkup,
    moduleHeaderMarkup,
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
    argumentsSectionMarkup,
    advancedGroupMarkup,
    advancedOptionsMarkup,
    optionFieldMarkup,
    outputFolderOptionsMarkup
  };
})(globalThis);
