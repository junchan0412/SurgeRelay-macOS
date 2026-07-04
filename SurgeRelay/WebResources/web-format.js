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

  function highlightCode(text) {
    return String(text ?? '').split('\n').map(line => {
      const trimmed = line.trim();
      let value = escapeHTML(line);
      if (/^\[[^\]]+\]$/.test(trimmed)) return `<span class="code-line code-section">${value}</span>`;
      if (/^(#|\/\/|;)/.test(trimmed)) return `<span class="code-line code-comment">${value}</span>`;
      value = value.replace(/(https?:\/\/[^\s,&lt;&gt;]+)/g, '<span class="code-url">$1</span>');
      value = value.replace(/^([A-Za-z][A-Za-z0-9_-]*)(\s*=)/, '<span class="code-key">$1</span>$2');
      value = value.replace(/\b(\d+(?:\.\d+)?)\b/g, '<span class="code-number">$1</span>');
      return `<span class="code-line">${value || ' '}</span>`;
    }).join('');
  }

  global.SurgeRelayWebFormat = {
    formatDate,
    formatTime,
    escapeHTML,
    escapeAttribute,
    highlightCode
  };
})(globalThis);
