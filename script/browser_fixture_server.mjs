import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

export async function startBrowserFixture() {
  const resources = resolve(fileURLToPath(new URL('../SurgeRelay/WebResources/', import.meta.url)));
  let count = 100;
  let workspace = null;
  let activityOverrides = {};
  let historyEntries = [];
  const contentKey = id => workspace ? `${workspace.id}:${id}` : id;
  const overrides = new Map();
  const contents = new Map();
  const requests = [];
  const streams = new Set();
  const tickets = new Map();
  const syncContents = new Map();
  let revision = 0;
  let serial = 0;
  let lastAttempt = null;
  const baseText = '#!name=Browser fixture\n[Rule]\nDOMAIN,example.invalid,DIRECT\n';
  const etag = text => `"${createHash('sha256').update(text).digest('hex')}"`;
  const moduleAt = index => ({ id: `module-${index}`, name: `Fixture Module ${String(index).padStart(5, '0')}`, sourceURL: 'https://fixture.invalid/source.plugin', sourceFormat: 'quantumultX', sourceFormatTitle: 'Quantumult X', initialSourceTitle: '测试订阅', initialSourceIcon: 'link', storageLocation: 'gitHub', storageTargets: ['gitHub'], storageLocationTitle: 'GitHub 模块', storageLocationDetail: '隔离 fixture', storageLocationIcon: 'cloud', outputFileName: `Fixture-${index}.sgmodule`, publishedRelativePath: `Fixture-${index}.sgmodule`, outputFolder: '', category: index % 2 ? 'Odd' : 'Even', iconURL: '', customIconURL: '', isEnabled: false, publishesStandalone: true, state: 'current', stateTitle: '已是最新', lastError: '', lastUpdatedAt: null, advancedSummary: '', scriptHubOptions: {}, ...overrides.get(`module-${index}`) });
  const state = () => ({
    ...(workspace ? { workspace } : {}),
    combined: { isEnabled: false, name: 'Fixture', fileName: 'Fixture', enabledCount: 0, sourceCount: count },
    activity: { kind: 'idle', title: '', status: '隔离 fixture', blocksUpdates: false, canCancel: false, cancellationRequested: false, isWorking: false, progress: null, canStartUpdate: true, updateBlockedReason: null, ...activityOverrides },
    moduleEditor: { defaultStorageLocation: 'gitHub', localOutputFolders: ['', 'Local'], githubOutputFolders: ['', 'Remote'], publishToLocal: true, publishToGitHub: true },
    modules: Array.from({ length: count }, (_, index) => moduleAt(index))
  });
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    const json = (body, status = 200, headers = {}) => { res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers }); res.end(JSON.stringify(body)); };
    try {
      if (url.pathname === '/__fixture/blank') { res.writeHead(200, { 'content-type': 'text/html' }); res.end('<!doctype html><title>Fixture seed</title>'); return; }
      if (workspace?.id && !['GET', 'HEAD'].includes(req.method) && !['/api/session', '/api/source/name'].includes(url.pathname) && ((req.headers['x-relay-workspace'] && req.headers['x-relay-workspace'] !== workspace.id) || (!workspace.isLegacyDefault && !req.headers['x-relay-workspace']))) return json({ message: 'fixture workspace mismatch' }, 412);
      if (url.pathname === '/api/events') {
        res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store' });
        res.write(`event: state\ndata: ${JSON.stringify(state())}\n\n`);
        streams.add(res); req.on('close', () => streams.delete(res)); return;
      }
      if (url.pathname === '/api/state') return json(state());
      if (url.pathname === '/api/session') return json({ message: 'fixture session' });
      if (url.pathname === '/api/history') return json(historyEntries);
      if (url.pathname.endsWith('/arguments')) return json({ arguments: [] });
      let body = '';
      for await (const chunk of req) body += chunk;
      if (url.pathname === '/api/source/name') return json({ name: 'Fixture Source' });
      if (url.pathname === '/api/publishing') return json({ attempt: lastAttempt, canPublishToGitHub: true, localEnabled: true });
      if (url.pathname === '/api/publish/preview' && req.method === 'POST') {
        const request = JSON.parse(body); const token = `fixture-publish-${++serial}`;
        const destinations = request.retryAttemptID ? ['gitHub'] : request.scope === 'githubAll' ? ['gitHub'] : ['local', 'gitHub'];
        const plan = { token, moduleIDs: request.moduleIDs || lastAttempt?.moduleIDs || [], previews: destinations.map(destination => ({ destination, targetDescription: destination === 'local' ? '/Fixture/Modules' : 'fixture/repository', activeFiles: ['Fixture.sgmodule'], changedFiles: ['Fixture.sgmodule'], deletedFiles: request.scope === 'githubAll' ? ['Obsolete.sgmodule'] : [], issues: [{ filePath: 'Fixture.sgmodule', line: 3, severity: 'warning', code: 'fixture-warning', message: 'Fixture warning for review', relatedLine: 2 }] })) };
        tickets.set(token, { revision, request, plan }); requests.push({ method: req.method, workspace: req.headers['x-relay-workspace'], path: url.pathname, payload: request }); return json(plan);
      }
      if (url.pathname === '/api/publish' && req.method === 'POST') {
        const payload = JSON.parse(body); const ticket = tickets.get(payload.token); tickets.delete(payload.token);
        requests.push({ method: req.method, workspace: req.headers['x-relay-workspace'], path: url.pathname, payload });
        if (!ticket || ticket.revision !== revision) return json({ message: 'fixture stale publication' }, 412);
        if (ticket.request.scope === 'githubAll') return json({ ok: true, message: 'Fixture GitHub publication completed' });
        const results = ticket.request.retryAttemptID
          ? lastAttempt.results.map(result => ({ ...result, status: 'succeeded', message: 'Fixture retry succeeded' }))
          : ticket.plan.previews.map(preview => ({ destination: preview.destination, target: preview.targetDescription, status: preview.destination === 'local' ? 'succeeded' : 'failed', message: preview.destination === 'local' ? 'Fixture local complete' : 'Fixture GitHub failure', publishedFiles: preview.destination === 'local' ? ['Fixture.sgmodule'] : [] }));
        lastAttempt = { id: `fixture-attempt-${++serial}`, moduleIDs: ticket.plan.moduleIDs, results }; return json({ ok: !results.some(result => result.status === 'failed'), message: 'Fixture selected publication finished', attempt: lastAttempt });
      }
      const history = url.pathname.match(/^\/api\/modules\/([^/]+)\/versions(?:\/([^/]+)(\/restore)?)?$/);
      if (history) {
        const id = history[1];
        const historicalText = '#!name=Historical fixture\n[Rule]\nDOMAIN,historical.invalid,DIRECT\n';
        const version = { id: 'fixture-history-1', createdAt: '2026-10-01T00:00:00Z', reason: 'beforeUpdate', contentHash: etag(historicalText).slice(1, -1), hasOverride: false, assets: [{ path: 'scripts/historical.js', contentHash: 'fixture-asset-hash', byteCount: 20 }], byteCount: Buffer.byteLength(historicalText) };
        if (!history[2]) return json([version]);
        if (history[3] && req.method === 'POST') {
          const payload = JSON.parse(body), ticket = tickets.get(payload.token); tickets.delete(payload.token);
          requests.push({ method: req.method, workspace: req.headers['x-relay-workspace'], path: url.pathname, payload });
          if (!ticket || ticket.revision !== revision || ticket.id !== id || ticket.versionID !== history[2]) return json({ message: 'fixture stale version restore' }, 412);
          contents.set(contentKey(id), historicalText); revision += 1; return json({ ok: true, message: 'Fixture historical cache restored' });
        }
        const token = `fixture-history-${++serial}`; tickets.set(token, { revision, id, versionID: history[2] });
        return json({ token, version, changedAssets: ['− scripts/historical.js', '+ scripts/current.js'], diff: { rows: [{ kind: 'removed', localLine: 1, text: '#!name=Historical fixture' }, { kind: 'added', githubLine: 1, text: '#!name=Browser fixture' }], addedCount: 1, removedCount: 1, isTruncated: false, usesCoarseComparison: false } });
      }
      const sync = url.pathname.match(/^\/api\/modules\/([^/]+)\/sync-conflict$/);
      if (sync) {
        const id = sync[1]; const sides = syncContents.get(id) || { localContent: 'local fixture line', gitHubContent: 'GitHub fixture line' };
        if (req.method === 'POST') {
          const payload = JSON.parse(body); const ticket = tickets.get(payload.token); tickets.delete(payload.token);
          requests.push({ method: req.method, workspace: req.headers['x-relay-workspace'], path: url.pathname, payload });
          if (!ticket || ticket.revision !== revision || ticket.id !== id) return json({ message: 'fixture stale sync' }, 412);
          if (payload.direction === 'localToGitHub') sides.gitHubContent = sides.localContent; else sides.localContent = sides.gitHubContent;
          syncContents.set(id, sides); revision += 1; return json({ message: 'Fixture synchronization complete' });
        }
        const token = `fixture-sync-${++serial}`; tickets.set(token, { revision, id });
        const same = sides.localContent === sides.gitHubContent;
        return json({ token, ...sides, state: same ? 'same' : 'bothChanged', stateTitle: same ? '两端内容一致' : '两端均已修改', diff: { rows: same ? [{ kind: 'context', localLine: 1, githubLine: 1, text: sides.localContent }] : [{ kind: 'removed', localLine: 1, text: sides.localContent }, { kind: 'added', githubLine: 1, text: sides.gitHubContent }], addedCount: same ? 0 : 1, removedCount: same ? 0 : 1, isTruncated: false, usesCoarseComparison: false } });
      }

      const preview = url.pathname.match(/^\/api\/modules\/([^/]+)\/preview$/);
      if (preview) {
        const id = preview[1];
        let text = contents.get(contentKey(id)) ?? baseText;
        if (req.method === 'PUT') {
          requests.push({ method: req.method, workspace: req.headers['x-relay-workspace'], path: url.pathname, ifMatch: req.headers['if-match'], bytes: Buffer.byteLength(body) });
          if (req.headers['if-match'] !== etag(text)) return json({ message: 'fixture concurrent version changed' }, 412);
          contents.set(contentKey(id), body); return json({ message: 'Fixture saved' }, 200, { etag: etag(body) });
        }
        if (req.method === 'DELETE') {
          if (req.headers['if-match'] !== etag(text)) return json({ message: 'fixture concurrent restore changed' }, 412);
          text = baseText; contents.set(contentKey(id), text);
        }
        res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', etag: etag(text), 'cache-control': 'no-store' }); res.end(text); return;
      }
      if (/^\/api\/modules(?:\/[^/]+)?$/.test(url.pathname) && ['POST', 'PUT'].includes(req.method)) {
        const payload = JSON.parse(body); const id = url.pathname.split('/')[3] || 'module-0';
        overrides.set(id, payload); requests.push({ method: req.method, workspace: req.headers['x-relay-workspace'], path: url.pathname, payload });
        return json({ message: 'Fixture module saved', moduleID: id });
      }
      if (url.pathname.startsWith('/api/')) return json({ message: 'Unknown fixture route' }, 404);
      const path = resolve(resources, `.${url.pathname === '/' ? '/index.html' : url.pathname}`);
      if (!path.startsWith(`${resources}/`)) return json({ message: 'not found' }, 404);
      const data = await readFile(path);
      const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png' }[extname(path)] || 'application/octet-stream';
      res.writeHead(200, { 'content-type': mime, 'cache-control': 'no-store' }); res.end(data);
    } catch (error) { if (!res.headersSent) json({ message: error.message }, 500); else res.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {
    origin: `http://127.0.0.1:${server.address().port}`,
    requests,
    setCount(value) { count = value; overrides.clear(); },
    setActivity(value) { activityOverrides = value; },
    setHistory(value) { historyEntries = value; },
    setContent(id, text) { contents.set(contentKey(id), text); },
    setDualTarget(id) { overrides.set(id, { storageTargets: ['local', 'gitHub'], storageLocation: 'local', hasSyncConflict: true }); },
    invalidateTickets() { revision += 1; },
    setWorkspace(id, isLegacyDefault = false) {
      workspace = { id, name: `Workspace ${id}`, isLegacyDefault }; revision += 1; lastAttempt = null;
      for (const stream of streams) stream.write(`event: state\ndata: ${JSON.stringify(state())}\n\n`);
    },
    content(id) { return contents.get(contentKey(id)) ?? baseText; },
    async close() { for (const stream of streams) stream.end(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  };
}
