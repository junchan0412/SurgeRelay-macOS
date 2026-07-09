import assert from 'node:assert/strict';
import { api, stateHelpers } from './harness.mjs';

const tokenHistory = { state: { route: 'modules' }, replacedURL: '', replaceState(state, title, url) { this.state = state; this.replacedURL = String(url); } };
const tokenClient = api.createAPIClient({
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => ({ ok: true }) }),
  Headers,
  location: { href: 'https://relay.example.test/?token=secret-token&module=one' },
  history: tokenHistory
});
assert.equal(tokenClient.initializeAccessToken(), 'secret-token');
assert.equal(tokenClient.accessToken, 'secret-token');
assert.doesNotMatch(tokenHistory.replacedURL, /token=/);
assert.match(tokenHistory.replacedURL, /module=one/);

let capturedRequest = null;
const requestClient = api.createAPIClient({
  fetch: async (path, options) => {
    capturedRequest = { path, options };
    return {
      ok: true,
      status: 200,
      headers: { get: name => name.toLowerCase() === 'content-type' ? 'application/json' : '' },
      json: async () => ({ saved: true })
    };
  },
  Headers,
  accessToken: 'token-1'
});
assert.deepEqual(await requestClient.request('/api/demo', {
  method: 'POST',
  json: { enabled: true },
  includeAccessToken: true
}), { saved: true });
assert.equal(capturedRequest.path, '/api/demo');
assert.equal(capturedRequest.options.method, 'POST');
assert.equal(capturedRequest.options.credentials, 'same-origin');
assert.equal(capturedRequest.options.headers.get('Content-Type'), 'application/json');
assert.equal(capturedRequest.options.headers.get('Authorization'), 'Bearer token-1');
assert.equal(capturedRequest.options.body, '{"enabled":true}');

const retryPaths = [];
const retryClient = api.createAPIClient({
  fetch: async path => {
    retryPaths.push(path);
    if (retryPaths.length === 1) {
      return { ok: false, status: 401, headers: { get: () => '' }, json: async () => ({ message: 'unauthorized' }) };
    }
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => ({ recovered: true }) };
  },
  Headers,
  prompt: () => 'fresh-token'
});
assert.deepEqual(await retryClient.request('/api/state'), { recovered: true });
assert.deepEqual(retryPaths, ['/api/state', '/api/session', '/api/state']);
assert.equal(retryClient.accessToken, 'fresh-token');

const navigationState = {
  combined: { isEnabled: true },
  modules: [{ id: 'module-1' }, { id: 'module-2' }]
};
assert.equal(stateHelpers.combinedEnabled(navigationState), true);
assert.equal(stateHelpers.fallbackSelection(navigationState, false), 'combined');
assert.equal(stateHelpers.fallbackSelection(navigationState, true), null);
const requestedSelection = stateHelpers.resolveInitialSelection(navigationState, {
  requestedModuleID: 'module-2',
  isMobile: false
});
assert.equal(requestedSelection.selectedID, 'module-2');
assert.equal(requestedSelection.hasSelection, true);
const mobileSelection = stateHelpers.resolveInitialSelection(navigationState, {
  requestedModuleID: 'missing',
  isMobile: true
});
assert.equal(mobileSelection.selectedID, null);
assert.equal(mobileSelection.hasSelection, false);
const normalizedSelection = stateHelpers.normalizeSelection({
  combined: { isEnabled: false },
  modules: [{ id: 'module-1' }]
}, 'combined', false);
assert.equal(normalizedSelection.selectedID, 'module-1');
assert.equal(normalizedSelection.changed, true);
assert.equal(
  stateHelpers.moduleIDFromLocation({ href: 'https://relay.example.test/?module=module-1&token=redacted' }),
  'module-1'
);
assert.doesNotMatch(
  String(stateHelpers.urlWithoutModule({ href: 'https://relay.example.test/?module=module-1&token=redacted' })),
  /module=/
);
assert.match(
  String(stateHelpers.urlWithModule({ href: 'https://relay.example.test/?token=redacted' }, 'module-2')),
  /module=module-2/
);
const initialHistoryWithModule = stateHelpers.initialHistoryTransition({
  href: 'https://relay.example.test/?module=module-1&token=redacted'
}, null);
assert.equal(initialHistoryWithModule.replace.state.view, 'list');
assert.equal(initialHistoryWithModule.replace.state.module, null);
assert.doesNotMatch(String(initialHistoryWithModule.replace.url), /module=/);
assert.equal(initialHistoryWithModule.push.state.view, 'detail');
assert.equal(initialHistoryWithModule.push.state.module, 'module-1');
assert.equal(initialHistoryWithModule.push.state.cameFromList, true);
assert.match(String(initialHistoryWithModule.push.url), /module=module-1/);
assert.equal(
  stateHelpers.initialHistoryTransition({ href: 'https://relay.example.test/' }, { surgeRelay: true }),
  null
);
const initialHistoryWithoutModule = stateHelpers.initialHistoryTransition({
  href: 'https://relay.example.test/?token=redacted'
}, null);
assert.equal(initialHistoryWithoutModule.replace.state.view, 'list');
assert.equal(initialHistoryWithoutModule.push, null);
assert.match(String(initialHistoryWithoutModule.replace.url), /token=redacted/);
const detailHistoryEntry = stateHelpers.detailHistoryEntry({ href: 'https://relay.example.test/' }, 'module-2', true);
assert.equal(detailHistoryEntry.state.view, 'detail');
assert.equal(detailHistoryEntry.state.cameFromList, true);
assert.match(String(detailHistoryEntry.url), /module=module-2/);
const listHistoryEntry = stateHelpers.listHistoryEntry({ href: 'https://relay.example.test/?module=module-2' });
assert.equal(listHistoryEntry.state.view, 'list');
assert.doesNotMatch(String(listHistoryEntry.url), /module=/);
assert.equal(stateHelpers.mobileBackAction({ surgeRelay: true, cameFromList: true }), 'back');
assert.equal(stateHelpers.mobileBackAction({ surgeRelay: true, cameFromList: false }), 'show-list');
assert.deepEqual(
  JSON.parse(JSON.stringify(stateHelpers.historyNavigationTarget({ href: 'https://relay.example.test/' }, { view: 'list' }, true, 'module-1'))),
  { action: 'show-list', moduleID: null }
);
assert.deepEqual(
  JSON.parse(JSON.stringify(stateHelpers.historyNavigationTarget({ href: 'https://relay.example.test/?module=module-2' }, { view: 'detail' }, true, 'module-1'))),
  { action: 'select', moduleID: 'module-2' }
);
assert.deepEqual(
  JSON.parse(JSON.stringify(stateHelpers.historyNavigationTarget({ href: 'https://relay.example.test/' }, { view: 'list' }, false, 'module-1'))),
  { action: 'select', moduleID: 'module-1' }
);

let eventSource = null;
const appliedStates = [];
const reloads = [];
const reconnectTimers = [];
let sessionRefreshCount = 0;
class TestEventSource {
  constructor(url) {
    this.url = url;
    this.listeners = new Map();
    eventSource = this;
  }

  addEventListener(type, handler) {
    this.listeners.set(type, handler);
  }

  close() {
    this.closed = true;
  }
}
const eventController = stateHelpers.createStateEventController({
  EventSource: TestEventSource,
  document: { hidden: false },
  setInterval: () => 0,
  setTimeout: (handler, delay) => {
    reconnectTimers.push({ handler, delay });
    return reconnectTimers.length;
  },
  applyState: (...args) => appliedStates.push(args),
  loadState: async (...args) => reloads.push(args),
  establishSession: async () => { sessionRefreshCount += 1; },
  reconnectDelay: 25
});
eventController.start();
assert.equal(eventSource.url, '/api/events');
eventSource.listeners.get('state')({ data: '{"modules":[]}' });
assert.equal(appliedStates[0][0].modules.length, 0);
assert.equal(appliedStates[0][1], false);
assert.equal(appliedStates[0][2], false);
eventSource.onerror();
await new Promise(resolve => setImmediate(resolve));
await new Promise(resolve => setImmediate(resolve));
assert.equal(eventSource.closed, true);
assert.equal(sessionRefreshCount, 1);
assert.deepEqual(reloads[0], [false, false]);
assert.equal(reconnectTimers[0].delay, 25);
