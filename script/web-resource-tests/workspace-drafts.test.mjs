import assert from 'node:assert/strict';
import { previewHelpers } from './harness.mjs';
const records = new Map();
const readScopes = [];
let failWrites = false;
const indexedDB = { open() {
  const request = {};
  setImmediate(() => {
    request.result = { close() {}, transaction(_name, mode) {
      const changes = [];
      const transaction = { objectStore: () => ({
        index() { return this; },
        getAll(scope) { readScopes.push(scope); const read = {}; setImmediate(() => { read.result = [...records.values()].filter(record => record.scope === scope); read.onsuccess?.(); }); return read; },
        put: record => changes.push(() => records.set(record.key, structuredClone(record))),
        delete: key => changes.push(() => records.delete(key))
      }) };
      setImmediate(() => setImmediate(() => {
        if (mode === 'readwrite' && failWrites) transaction.onabort?.();
        else { changes.forEach(change => change()); transaction.oncomplete?.(); }
      }));
      return transaction;
    } };
    request.onsuccess?.();
  });
  return request;
} };
const local = new Map();
const storage = { getItem: key => local.get(key) ?? null, setItem: (key, value) => local.set(key, value), removeItem: key => local.delete(key) };
const origin = 'https://same-server.example';
const path = '/api/modules/same-id/preview';
const legacyScope = `surge-relay:drafts:v1:${origin}`;
records.set(`${legacyScope}:${path}`, { key: `${legacyScope}:${path}`, scope: legacyScope, path, text: 'legacy database draft', savedText: 'server legacy', updatedAt: 2 });
local.set(legacyScope, JSON.stringify([[path, { text: 'legacy local draft', savedText: 'server legacy', updatedAt: 1 }]]));
let workspace = 'A';
const server = new Map([['A', 'server A'], ['B', 'server B'], ['legacy', 'server legacy']]);
let pendingSave;
const nodes = Object.fromEntries(['#code-editor', '#preview-message', '[data-action="recover-draft"]'].map(key => [key, { value: '', hidden: true, addEventListener(type, callback) { this[type] = callback; } }]));
const controller = previewHelpers.createWorkspacePreviewController({
  draftScope: origin, storage, indexedDB,
  document: { querySelector: selector => nodes[selector] || null },
  api: async (_path, options = {}) => {
    if (options.method === 'PUT') {
      if (pendingSave) return pendingSave;
      server.set(workspace, options.body);
      return { body: { message: 'saved', content: options.body }, etag: `"${workspace}-saved"` };
    }
    return { body: server.get(workspace), etag: `"${workspace}"` };
  }
});
const edit = text => { nodes['#code-editor'].value = text; nodes['#code-editor'].input(); };
async function enter(id, legacy = false) {
  workspace = id;
  await controller.switchWorkspace({ id, name: id, isLegacyDefault: legacy });
  await controller.loadPreview(path, true);
}
await enter('A');
assert.deepEqual(readScopes, [`${legacyScope}:workspace:A`], 'nonlegacy initialization reads only its IndexedDB scope index');
assert.equal(controller.text, 'server A');
assert.equal(nodes['[data-action="recover-draft"]'].hidden, true, 'nonlegacy workspace must not import origin-only IndexedDB or localStorage drafts');
edit('draft A');
await enter('B');
assert.equal(controller.text, 'server B');
assert.equal(nodes['[data-action="recover-draft"]'].hidden, true, 'same module ID in another workspace does not expose prior draft');
edit('draft B');
await enter('A');
controller.recoverDraft();
assert.equal(controller.text, 'draft A');
assert.ok([...records.values()].some(record => record.scope.endsWith('workspace:B') && record.text === 'draft B'), 'switching never deletes the old workspace records');
let finishSave;
pendingSave = new Promise(resolve => { finishSave = resolve; });
const saving = controller.savePreview({ id: 'same-id' });
await enter('B');
controller.recoverDraft();
finishSave({ body: { message: 'old response', content: 'old workspace canonical text' }, etag: '"old"' });
await saving; pendingSave = null;
assert.equal(controller.text, 'draft B', 'a late save response cannot cross into the new workspace');
assert.equal(controller.savedText, 'server B');
await enter('legacy', true);
assert.equal(nodes['[data-action="recover-draft"]'].hidden, false);
controller.recoverDraft();
assert.equal(controller.text, 'legacy database draft', 'only the marked legacy workspace imports the newest origin draft');
assert.ok(records.has(`${legacyScope}:${path}`), 'migration copies rather than deleting the original scope');
assert.ok(local.has(legacyScope));
await controller.savePreview({ id: 'same-id' });
await enter('B');
await enter('legacy', true);
assert.equal(nodes['[data-action="recover-draft"]'].hidden, true, 'migration marker prevents old drafts resurrecting after successful save');
await enter('A');
controller.recoverDraft();
edit('A survives quota failure');
failWrites = true;
await enter('B');
failWrites = false;
await enter('A');
controller.recoverDraft();
assert.equal(controller.text, 'A survives quota failure', 'failed old-scope flush retains a workspace-scoped memory recovery copy');
await assert.rejects(controller.switchWorkspace(undefined), /缺少工作区信息/);
const rapidB = controller.switchWorkspace({ id: 'B', isLegacyDefault: false });
const rapidA = controller.switchWorkspace({ id: 'A', isLegacyDefault: false });
await Promise.all([rapidB, rapidA]);
await controller.loadPreview(path, true); controller.recoverDraft();
assert.equal(controller.text, 'A survives quota failure');
console.log('Workspace draft isolation and legacy migration tests passed');
