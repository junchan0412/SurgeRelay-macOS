import assert from 'node:assert/strict';
import { detailHelpers, markup } from './harness.mjs';

const modules = [{ id: 'm1', name: 'Module <one>', publishesStandalone: true }, { id: 'm2', name: 'Internal only', publishesStandalone: false }];
let checked = ['m1'];
const ui = {
  operationDialog: { open: false, addEventListener() {} },
  operationTitle: { textContent: '' },
  operationContent: { innerHTML: '', querySelectorAll: () => checked.map(id => ({ dataset: { publishModule: id } })), querySelector: () => ({ disabled: false }) }
};
const requests = [];
let confirmed = true;
let stale = false;
let retrying = false;
let previewResponse = null;
let attempt = { id: 'attempt-1', moduleIDs: ['m1'], results: [{ destination: 'local', target: '/Fixture', status: 'succeeded', message: 'local done', publishedFiles: ['one.sgmodule'] }, { destination: 'gitHub', target: 'owner/repo', status: 'failed', message: 'offline', publishedFiles: [] }] };
let syncToken = 'sync-v1';
const confirmations = [];
const controller = detailHelpers.createPublishingController({
  ui, markup, getState: () => ({ modules }),
  openDialog: dialog => { dialog.open = true; }, closeDialog: dialog => { dialog.open = false; },
  askConfirmation: async (...args) => { confirmations.push(args); return confirmed; },
  api: async (path, options = {}) => {
    requests.push({ path, options });
    if (path === '/api/publish/preview') {
      if (previewResponse) return previewResponse;
      retrying = Boolean(options.json.retryAttemptID);
      return { token: retrying ? 'retry-token' : 'publish-token', previews: [{ destination: 'gitHub', targetDescription: 'owner/repo <main>', activeFiles: ['one.sgmodule'], changedFiles: ['<one>.sgmodule'], deletedFiles: ['old.sgmodule'], issues: [{ filePath: '<one>.sgmodule', line: 12, severity: 'warning', code: 'duplicate-rule', message: '与已有规则重复 <check>', relatedLine: 3 }] }] };
    }
    if (path === '/api/publish') {
      if (stale) throw Object.assign(new Error('stale'), { status: 412 });
      return { message: 'done', attempt: options.json.token === 'retry-token' ? { ...attempt, results: attempt.results.map(result => ({ ...result, status: 'succeeded' })) } : attempt };
    }
    if (path === '/api/publishing') return { attempt };
    if (path.endsWith('/sync-conflict')) {
      if (options.method === 'POST') {
        if (stale) throw Object.assign(new Error('stale'), { status: 412 });
        return { message: 'synced' };
      }
      return { token: syncToken, state: 'bothChanged', stateTitle: '两端均已修改', localContent: 'local <script>', gitHubContent: 'remote', diff: { rows: [{ kind: 'removed', localLine: 1, text: '<script>' }, { kind: 'added', githubLine: 1, text: 'remote' }], addedCount: 1, removedCount: 1, isTruncated: true } };
    }
    throw new Error(`unexpected ${path}`);
  }
});
const click = action => controller.handleClick({ target: { closest: () => ({ dataset: { operation: action } }) } });
controller.openSelected('m1');
assert.match(ui.operationContent.innerHTML, /Module &lt;one&gt;/);
assert.doesNotMatch(ui.operationContent.innerHTML, /Internal only/);
await click('preview-selected');
assert.deepEqual(JSON.parse(JSON.stringify(requests.at(-1).options.json)), { moduleIDs: ['m1'] });
assert.match(ui.operationContent.innerHTML, /old.sgmodule/);
assert.match(ui.operationContent.innerHTML, /&lt;one&gt;/);
assert.match(ui.operationContent.innerHTML, /&lt;one&gt;\.sgmodule:12/);
assert.match(ui.operationContent.innerHTML, /与已有规则重复 &lt;check&gt;/);
assert.match(ui.operationContent.innerHTML, /相关行 3/);
assert.match(ui.operationContent.innerHTML, /确认并继续发布/);
assert.equal(requests.filter(request => request.path === '/api/publish').length, 0, 'preview does not publish');
confirmed = false;
await click('execute-publish');
assert.equal(requests.filter(request => request.path === '/api/publish').length, 0);
confirmed = true;
await click('execute-publish');
assert.match(confirmations.at(-1)[1], /删除 1 个文件/);
assert.equal(confirmations.at(-1)[2], '继续发布');
assert.equal(requests.at(-1).options.json.token, 'publish-token');
assert.match(ui.operationContent.innerHTML, /本地 · 成功/);
assert.match(ui.operationContent.innerHTML, /GitHub · 失败/);
await click('retry-publish');
assert.deepEqual(JSON.parse(JSON.stringify(requests.at(-1).options.json)), { retryAttemptID: 'attempt-1' });
assert.equal(retrying, true);
await click('execute-publish');
assert.equal(requests.at(-1).options.json.token, 'retry-token');
assert.doesNotMatch(ui.operationContent.innerHTML, /data-operation="retry-publish"/);
await controller.showLastResult();
assert.equal(requests.at(-1).path, '/api/publishing');
assert.match(ui.operationContent.innerHTML, /offline/);
await controller.openGitHub();
assert.deepEqual(JSON.parse(JSON.stringify(requests.at(-1).options.json)), { scope: 'githubAll' });
stale = true;
await click('execute-publish');
assert.match(ui.operationContent.innerHTML, /内容或配置已变化/);
const writesAfterStale = requests.filter(request => request.path === '/api/publish').length;
await click('execute-publish');
assert.equal(requests.filter(request => request.path === '/api/publish').length, writesAfterStale, 'stale ticket cannot be reused');
stale = false;
await controller.openSync(modules[0]);
assert.match(ui.operationContent.innerHTML, /diff-removed/);
assert.match(ui.operationContent.innerHTML, /&lt;script&gt;/);
assert.match(ui.operationContent.innerHTML, /简化或截断/);
confirmed = false;
await click('local-to-github');
assert.equal(requests.at(-1).options.method, undefined, 'cancelled direction confirmation does not write');
confirmed = true; stale = true;
await click('local-to-github');
assert.deepEqual(JSON.parse(JSON.stringify(requests.at(-1).options.json)), { token: 'sync-v1', direction: 'localToGitHub' });
assert.match(ui.operationContent.innerHTML, /重新比较/);
stale = false; syncToken = 'sync-v2';
await click('refresh-sync');
await click('github-to-local');
assert.deepEqual(JSON.parse(JSON.stringify(requests.at(-1).options.json)), { token: 'sync-v2', direction: 'gitHubToLocal' });
assert.match(confirmations.at(-1)[0], /用 GitHub 覆盖本地/);

let finishPreview;
previewResponse = new Promise(resolve => { finishPreview = resolve; });
controller.openSelected('m1');
const pending = click('preview-selected');
const requestCount = requests.length;
await click('preview-selected');
assert.equal(requests.length, requestCount, 'duplicate preview clicks are coalesced');
controller.close();
controller.openSelected();
finishPreview({ token: 'obsolete', previews: [] });
await pending;
assert.match(ui.operationContent.innerHTML, /选择要发布/);
assert.doesNotMatch(ui.operationContent.innerHTML, /确认发布以上变更/, 'closed-dialog responses cannot replace a newly opened selection');
console.log('Publishing and synchronization controller tests passed');
