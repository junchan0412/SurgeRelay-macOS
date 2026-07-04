(function installSurgeRelayWebAPI(global) {
  function createAPIClient(dependencies = {}) {
    const fetchImpl = dependencies.fetch || global.fetch;
    const HeadersImpl = dependencies.Headers || global.Headers;
    const locationRef = dependencies.location || global.location;
    const historyRef = dependencies.history || global.history;
    const promptImpl = dependencies.prompt || (message => global.prompt?.(message));
    let accessToken = String(dependencies.accessToken || '').trim();

    function initializeAccessToken() {
      if (!locationRef?.href) return accessToken;
      const url = new URL(locationRef.href);
      const token = url.searchParams.get('token') || '';
      accessToken = token.trim();
      if (token) {
        url.searchParams.delete('token');
        historyRef?.replaceState?.(historyRef.state, '', url);
      }
      return accessToken;
    }

    function storeAccessToken(token) {
      accessToken = String(token || '').trim();
      return accessToken;
    }

    async function promptForAccessToken() {
      const token = promptImpl('请输入 Web 管理访问令牌');
      if (!token) return false;
      storeAccessToken(token);
      return true;
    }

    async function establishSession() {
      if (!accessToken) return;
      await request('/api/session', { method: 'POST', includeAccessToken: true });
    }

    async function request(path, options = {}, retrying = false) {
      const headers = new HeadersImpl(options.headers || {});
      let body = options.body;
      if (options.json !== undefined) {
        headers.set('Content-Type', 'application/json');
        body = JSON.stringify(options.json);
      }
      if (options.includeAccessToken && accessToken) {
        headers.set('Authorization', `Bearer ${accessToken}`);
      }
      const response = await fetchImpl(path, {
        method: options.method || 'GET',
        headers,
        body,
        credentials: 'same-origin'
      });
      if (response.status === 401 && !retrying && await promptForAccessToken()) {
        if (path !== '/api/session') {
          await establishSession();
        }
        return request(path, options, true);
      }
      if (!response.ok) {
        let message = `请求失败（${response.status}）`;
        try {
          message = (await response.json()).message || message;
        } catch (_) {}
        throw new Error(message);
      }
      const contentType = response.headers.get('content-type') || '';
      return contentType.includes('application/json') ? response.json() : response.text();
    }

    return {
      initializeAccessToken,
      storeAccessToken,
      promptForAccessToken,
      establishSession,
      request,
      get accessToken() {
        return accessToken;
      }
    };
  }

  global.SurgeRelayWebAPI = { createAPIClient };
})(globalThis);
