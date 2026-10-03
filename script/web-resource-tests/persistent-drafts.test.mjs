import assert from 'node:assert/strict';
import { previewHelpers, markup } from './harness.mjs';

const data = new Map();
let fails = false;
const storage = {
  getItem: key => data.get(key) ?? null,
  setItem(key, value) { if (fails) throw new Error('quota'); data.set(key, value); },
  removeItem: key => data.delete(key)
};
const path = '/api/modules/demo/preview';
let serverText = 'original';
let pendingSave = null;
let writes = 0;
let accepted = true;
let currentTime = 1000000000;
function session(scope = 'https://relay.example', extra = {}) {
  const nodes = Object.fromEntries(['#code-editor', '#preview-message', '#preview-status', '[data-action="save-preview"]', '[data-action="recover-draft"]', '[data-action="discard-draft"]'].map(selector => [selector, { dataset: {}, value: '', addEventListener(type, callback) { this[type] = callback; } }]));
  const notices = [];
  const confirmations = [];
  const controller = previewHelpers.createPreviewController({
    storage, draftScope: scope, now: () => currentTime, ...extra,
    document: { querySelector: selector => nodes[selector] || null },
    api: async (_path, options = {}) => {
      if (options.method === 'PUT') { writes += 1; if (pendingSave) await pendingSave; serverText = options.body; return { message: 'saved' }; }
      if (options.method === 'DELETE') { writes += 1; serverText = 'converted'; }
      return serverText;
    },
    askConfirmation: async title => { confirmations.push(title); return accepted; },
    showToast: text => notices.push(text)
  });
  const edit = text => { nodes['#code-editor'].value = text; nodes['#code-editor'].input(); };
  return { controller, nodes, edit, notices, confirmations };
}
let first = session();
await first.controller.loadPreview(path, true);
first.edit('my draft');
first.controller.flushDrafts();
assert.equal(data.size, 1);
assert.doesNotMatch([...data.keys()][0], /token/);
let reopened = session();
await reopened.controller.loadPreview(path, true);
assert.equal(reopened.controller.text, 'original', 'loading a stored draft first displays the server version');
assert.equal(reopened.nodes['[data-action="recover-draft"]'].hidden, false);
assert.equal(reopened.nodes['#code-editor'].disabled, true, 'recovery decision cannot accidentally overwrite the stored draft');
assert.equal(writes, 0, 'reading persisted drafts never writes to the server');
await reopened.controller.restorePreview({ id: 'demo', name: 'Demo' });
assert.equal(writes, 0, 'conversion restore cannot bypass the pending draft decision');
reopened.controller.recoverDraft();
assert.equal(reopened.controller.text, 'my draft');
assert.equal(reopened.nodes['#code-editor'].disabled, false);
let isolated = session('https://other-relay.example');
await isolated.controller.loadPreview(path, true);
assert.equal(isolated.nodes['[data-action="recover-draft"]'].hidden, true, 'service addresses are isolated');

serverText = 'upstream changed';
reopened = session();
await reopened.controller.loadPreview(path, true);
assert.match(reopened.nodes['#preview-message'].textContent, /服务器内容已变化/);
reopened.controller.recoverDraft();
accepted = false;
await reopened.controller.savePreview({ id: 'demo' });
assert.equal(writes, 0, 'conflicting recovered draft requires explicit overwrite confirmation');
accepted = true;
let finishSave;
pendingSave = new Promise(resolve => { finishSave = resolve; });
const saving = reopened.controller.savePreview({ id: 'demo' });
await new Promise(resolve => setImmediate(resolve));
reopened.edit('newer typing');
finishSave();
await saving;
pendingSave = null;
assert.equal(reopened.controller.text, 'newer typing');
assert.equal(reopened.controller.savedText, 'my draft');
let afterSave = session();
await afterSave.controller.loadPreview(path, true);
afterSave.controller.recoverDraft();
assert.equal(afterSave.controller.text, 'newer typing', 'typing during save survives another reload');
assert.equal(afterSave.controller.savedText, 'my draft', 'successful save advances the durable baseline');
await afterSave.controller.savePreview({ id: 'demo' });
assert.equal(data.size, 0, 'fully saved draft is removed from persistent storage');

afterSave.edit('discard me');
afterSave.controller.flushDrafts();
let beforeDiscardWrites = writes;
accepted = false;
await afterSave.controller.discardDraft();
assert.equal(data.size, 1, 'cancelling discard keeps the persistent draft');
accepted = true;
await afterSave.controller.discardDraft();
assert.equal(data.size, 0);
assert.equal(writes, beforeDiscardWrites, 'discarding a browser draft never changes server data');
afterSave.edit('restore me');
await afterSave.controller.restorePreview({ id: 'demo', name: 'Demo' });
assert.equal(afterSave.controller.text, 'converted');
assert.equal(data.size, 0, 'restoring converted content removes the obsolete draft');

first = session();
await first.controller.loadPreview(path, true);
first.edit('quota draft');
fails = true;
first.controller.flushDrafts();
assert.equal(first.controller.text, 'quota draft');
assert.match(first.nodes['#preview-message'].textContent, /未持久化/);
assert.match(first.notices.at(-1), /未能保存到浏览器/);
fails = false;
first.controller.flushDrafts();
assert.doesNotMatch(first.nodes['#preview-message'].textContent, /未持久化/);
first.controller.forgetModule('demo');
assert.equal(data.size, 0, 'module deletion removes persisted draft');
first = session();
await first.controller.loadPreview(path, true);
first.edit('x'.repeat(1536 * 1024 + 1));
first.controller.flushDrafts();
assert.equal(data.size, 0, 'oversized drafts stay in memory');
assert.equal(first.controller.text.length, 1536 * 1024 + 1);
first.edit('expires');
first.controller.flushDrafts();
assert.equal(data.size, 1);
currentTime += 8 * 24 * 60 * 60 * 1000;
const expired = session();
await expired.controller.loadPreview(path, true);
assert.equal(expired.nodes['[data-action="recover-draft"]'].hidden, false, 'old unsaved drafts are retained until explicitly deleted');
await expired.controller.discardDraft();
assert.equal(data.size, 0);
assert.match(markup.previewShell('test', true), /recover-draft/);

const timers = new Map();
let nextTimer = 0;
const debounced = session('https://timer.example', {
  setTimeout(callback, delay) { assert.equal(delay, 400); timers.set(++nextTimer, callback); return nextTimer; },
  clearTimeout: timer => timers.delete(timer)
});
await debounced.controller.loadPreview(path, true);
debounced.edit('first keystroke');
debounced.edit('second keystroke');
assert.equal(timers.size, 1, 'typing coalesces browser storage writes');
assert.equal(data.size, 0);
debounced.controller.deactivate();
assert.equal(timers.size, 0);
assert.equal(data.size, 1, 'leaving the pane flushes the pending latest draft');
const afterDeactivate = session('https://timer.example');
await afterDeactivate.controller.loadPreview(path, true);
afterDeactivate.controller.recoverDraft();
assert.equal(afterDeactivate.controller.text, 'second keystroke');

let finishDeletedSave;
pendingSave = new Promise(resolve => { finishDeletedSave = resolve; });
afterDeactivate.edit('saving deleted module');
const deletedSave = afterDeactivate.controller.savePreview({ id: 'demo' });
afterDeactivate.controller.forgetModule('demo');
finishDeletedSave();
await deletedSave;
pendingSave = null;
assert.equal(data.size, 0, 'a late save response cannot resurrect a deleted module draft');
console.log('Persistent browser draft tests passed');

function fakeIndexedDB() {
  const records = new Map();
  let failWrites = false;
  const db = {
    createObjectStore() {}, close() {},
    transaction(_name, mode) {
      const pending = [];
      const transaction = {
        objectStore() { return {
          index() { return this; },
          getAll(scope) { const request = {}; setImmediate(() => { request.result = [...records.values()].filter(record => record.scope === scope); request.onsuccess?.(); }); return request; },
          put(record) { pending.push(() => records.set(record.key, structuredClone(record))); },
          delete(key) { pending.push(() => records.delete(key)); }
        }; }
      };
      setImmediate(() => setImmediate(() => {
        if (mode === 'readwrite' && failWrites) { transaction.error = new Error('quota exceeded'); transaction.onabort?.(); }
        else { pending.forEach(change => change()); transaction.oncomplete?.(); }
      }));
      return transaction;
    }
  };
  return { records, set failWrites(value) { failWrites = value; }, open() { const request = {}; setImmediate(() => { request.result = db; request.onsuccess?.(); }); return request; } };
}
const idb = fakeIndexedDB();
let large = session('https://large.example', { indexedDB: idb });
await large.controller.loadPreview(path, true);
const largeText = '规则'.repeat(3 * 1024 * 1024);
large.edit(largeText);
await large.controller.flushDrafts();
assert.equal(idb.records.size, 1);
assert.equal([...idb.records.values()][0].text, largeText, 'IndexedDB persists documents larger than 5 MiB');
large = session('https://large.example', { indexedDB: idb });
await large.controller.loadPreview(path, true);
large.controller.recoverDraft();
assert.equal(large.controller.text, largeText);
idb.failWrites = true;
large.edit(largeText + '追加');
await large.controller.flushDrafts();
assert.match(large.nodes['#preview-message'].textContent, /未持久化/);
assert.equal(large.controller.text, largeText + '追加');
idb.failWrites = false;
await large.controller.flushDrafts();
assert.equal([...idb.records.values()][0].text, largeText + '追加');
await large.controller.discardDraft();
await large.controller.flushDrafts();
assert.equal(idb.records.size, 0);

const legacy = session('https://migrate.example');
await legacy.controller.loadPreview(path, true);
legacy.edit('legacy localStorage draft');
legacy.controller.flushDrafts();
assert.equal(data.size, 1);
const migrated = session('https://migrate.example', { indexedDB: idb });
await migrated.controller.loadPreview(path, true);
assert.equal(data.size, 0, 'legacy localStorage copy is removed only after IndexedDB commits migration');
migrated.controller.recoverDraft();
assert.equal(migrated.controller.text, 'legacy localStorage draft');
assert.equal(idb.records.size, 1);
for (let index = 0; index < 25; index += 1) {
  await migrated.controller.loadPreview(`/api/modules/module-${index}/preview`, true);
  migrated.edit(`unsaved-${index}`);
}
await migrated.controller.flushDrafts();
assert.equal(idb.records.size, 26, 'more than 20 unsaved drafts are retained');
console.log('IndexedDB large draft tests passed');
