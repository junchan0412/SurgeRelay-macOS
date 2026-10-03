(function installSurgeRelayWebFormat(global) {
  function formatDate(value, fallback = '—') {
    if (!value) return fallback;
    const date = new Date(value);
    if (Number.isNaN(date.valueOf())) return fallback;
    return new Intl.DateTimeFormat('zh-CN', {
      dateStyle: 'medium',
      timeStyle: 'medium'
    }).format(date);
  }

  function formatTime(value, fallback = '—') {
    if (!value) return fallback;
    const date = new Date(value);
    if (Number.isNaN(date.valueOf())) return fallback;
    return new Intl.DateTimeFormat('zh-CN', { timeStyle: 'medium' }).format(date);
  }

  function escapeHTML(value) {
    return String(value ?? '').replace(/[&<>'"]/g, character => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      "'": '&#39;',
      '"': '&quot;'
    })[character]);
  }

  function escapeAttribute(value) {
    return escapeHTML(value);
  }

  function stageMetricPresentation(metric = {}) {
    const stages = { download: '下载', conversion: '转换', cache: '缓存', publish: '发布' };
    const results = { completed: '已完成', failed: '失败', skipped: '跳过', cancelled: '已取消' };
    const count = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value.toLocaleString('zh-CN') : '未采集';
    const bytes = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 ? `${count(value)} 字节` : '未采集';
    return {
      stage: metric.stage === 'conversion' && metric.includesDownload ? '转换/下载（未拆分）' : stages[metric.stage] || metric.stage || '未知阶段',
      duration: typeof metric.duration === 'number' && Number.isFinite(metric.duration) ? `${metric.duration.toFixed(2)} 秒` : '未采集',
      read: bytes(metric.bytesRead), written: bytes(metric.bytesWritten),
      attempts: count(metric.attempts), failedAttempts: count(metric.failedAttempts),
      result: results[metric.result] || metric.result || '未知结果',
      partial: metric.isPartial ? '部分测量' : '', reason: metric.reason || ''
    };
  }

  function historyRecordText(entry) {
    if (!entry) return '';
    const lines = [entry.moduleName || 'Surge Relay', formatDate(entry.date), entry.outcome || '', entry.message || ''];
    if (typeof entry.duration === 'number') lines.push(`总耗时（记录）：${entry.duration.toFixed(2)} 秒`);
    if (Array.isArray(entry.stageMetrics) && entry.stageMetrics.length) {
      lines.push('性能明细：阶段可能并行，不可相加作为总耗时。内容字节不代表 TLS 流量或物理 I/O。');
      for (const metric of entry.stageMetrics.slice(0, 4)) {
        const item = stageMetricPresentation(metric);
        lines.push(`${item.stage}：${item.duration} · ${item.result}${item.partial ? ` · ${item.partial}` : ''}`,
          `读取内容字节：${item.read}；写入内容字节：${item.written}`,
          `尝试 ${item.attempts} 次；失败尝试 ${item.failedAttempts} 次`);
        if (item.reason) lines.push(`说明：${item.reason}`);
      }
    }
    return lines.filter(Boolean).join('\n');
  }

  function highlightCode(text) {
    return String(text ?? '').split('\n').map(line => {
      const trimmed = line.trim();
      let value = escapeHTML(line);
      if (/^\[[^\]]+\]$/.test(trimmed)) return `<span class="code-line code-section">${value}</span>`;
      if (/^(?:#|\/\/|;)SUBSCRIBED\b/.test(trimmed)) return `<span class="code-line code-subscribed">${value}</span>`;
      if (/^(?:#|\/\/|;)/.test(trimmed)) return `<span class="code-line code-comment">${value}</span>`;
      value = value.replace(/(https?:\/\/[^\s,&lt;&gt;]+)/g, '<span class="code-url">$1</span>');
      value = value.replace(/^([A-Za-z][A-Za-z0-9_-]*)(\s*=)/, '<span class="code-key">$1</span>$2');
      value = value.replace(/\b(\d+(?:\.\d+)?)\b/g, '<span class="code-number">$1</span>');
      return `<span class="code-line">${value || ' '}</span>`;
    }).join('');
  }

  global.SurgeRelayWebFormat = {
    stageMetricPresentation, historyRecordText,
    formatDate,
    formatTime,
    escapeHTML,
    escapeAttribute,
    highlightCode
  };
})(globalThis);
