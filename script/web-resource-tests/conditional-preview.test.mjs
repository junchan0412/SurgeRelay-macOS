import assert from 'node:assert/strict';
import { api, previewHelpers } from './harness.mjs';
let serverText = 'version one';
let etag = '"one"';
const writes = [];
let raceDuringConfirmation = false;
const client = api.createAPIClient({
  Headers,
  fetch: async (_path, options) => {
    if (options.method === 'PUT') {
      writes.push(options.headers.get('If-Match'));
      if (options.headers.get('If-Match') !== etag) return { ok: false, status: 412, json: async () => ({ message: 'changed' }) };
      serverText = options.body;
      etag = '"saved"';
      return { ok: true, headers: new Headers({ 'content-type': 'application/json', etag }), json: async () => ({ message: 'saved' }) };
    }
    return { ok: true, headers: new Headers({ 'content-type': 'text/plain', etag }), text: async () => serverText };
  }
});
const nodes = Object.fromEntries(['#code-editor', '#server-preview', '#preview-message', '[data-action="save-preview"]'].map(key => [key, { hidden: true, addEventListener(type, callback) { this[type] = callback; } }]));
const controller = previewHelpers.createPreviewController({
  api: client.request,
  document: { querySelector: selector => nodes[selector] || null },
  storage: { getItem: () => null, setItem() {}, removeItem() {} },
  askConfirmation: async () => {
    if (raceDuringConfirmation) { serverText = 'changed again'; etag = '"three"'; raceDuringConfirmation = false; }
    return true;
  }
});
await controller.loadPreview('/api/modules/demo/preview', true);
nodes['#code-editor'].value = 'my edits';
nodes['#code-editor'].input();
serverText = 'someone else edits';
etag = '"two"';
await controller.savePreview({ id: 'demo' });
assert.deepEqual(writes, ['"one"']);
assert.equal(serverText, 'someone else edits', 'stale conditional save never overwrites newer server content');
assert.equal(controller.text, 'my edits');
assert.match(nodes['#preview-message'].textContent, /服务器内容已变化/);
controller.comparePreview();
assert.equal(nodes['#server-preview'].textContent, serverText);
assert.equal(nodes['#server-preview'].hidden, false);
raceDuringConfirmation = true;
await controller.savePreview({ id: 'demo' });
assert.deepEqual(writes, ['"one"', '"two"'], 'confirmed overwrite still uses the compared ETag');
assert.equal(serverText, 'changed again', 'another intervening edit produces another conflict');
assert.equal(controller.text, 'my edits');
await controller.savePreview({ id: 'demo' });
assert.deepEqual(writes, ['"one"', '"two"', '"three"']);
assert.equal(serverText, 'my edits');
nodes['#code-editor'].value = 'next edits';
nodes['#code-editor'].input();
await controller.savePreview({ id: 'demo' });
assert.equal(writes.at(-1), '"saved"', 'successful response advances the next request ETag');
assert.equal(serverText, 'next edits');
console.log('Conditional preview save tests passed');

let unsafeWrites = 0;
const noVersionEditor = { value: '', addEventListener(type, callback) { this[type] = callback; } };
const noVersion = previewHelpers.createPreviewController({
  api: async (_path, options) => { if (options.method === 'PUT') unsafeWrites += 1; return { body: 'no version', etag: null }; },
  document: { querySelector: selector => selector === '#code-editor' ? noVersionEditor : null }
});
await noVersion.loadPreview('/api/modules/no-version/preview', true);
noVersionEditor.value = 'changed';
noVersionEditor.input();
await noVersion.savePreview({ id: 'no-version' });
assert.equal(unsafeWrites, 0, 'a real metadata response without ETag never falls back to unconditional writes');

const normalizedStorage = new Map();
let canonical = '#!name=Original\n[Rule]\n';
let canonicalETag = '"initial"';
let completeNormalizedSave;
let holdNormalizedSave = false;
function normalizedSession() {
  const editor = { value: '', addEventListener(type, callback) { this[type] = callback; } };
  const message = { hidden: true, textContent: '' };
  const controller = previewHelpers.createPreviewController({
    storage: { getItem: key => normalizedStorage.get(key) ?? null, setItem: (key, value) => normalizedStorage.set(key, value), removeItem: key => normalizedStorage.delete(key) },
    draftScope: 'normalized-server',
    api: async (_path, options = {}) => {
      if (options.method === 'PUT') {
        assert.equal(options.headers['If-Match'], canonicalETag);
        if (holdNormalizedSave) await new Promise(resolve => { completeNormalizedSave = resolve; });
        canonical = options.body.replace(/^#!name=.*$/m, '#!name=Canonical Module');
        canonicalETag = '"normalized"';
        return { body: { message: 'saved', content: canonical }, etag: canonicalETag };
      }
      return { body: canonical, etag: canonicalETag };
    },
    document: { querySelector: selector => selector === '#code-editor' ? editor : selector === '#preview-message' ? message : null }
  });
  return { controller, editor, message, edit(text) { editor.value = text; editor.input(); } };
}
let normalized = normalizedSession();
await normalized.controller.loadPreview('/api/modules/normalized/preview', true);
normalized.edit('#!name=User Typed Name\n[Rule]\nDOMAIN,one.invalid,DIRECT');
await normalized.controller.savePreview({ id: 'normalized' });
assert.equal(normalized.controller.savedText, canonical, 'actual metadata-normalized response becomes the saved baseline');
assert.equal(normalized.controller.text, canonical, 'unchanged submitted text is replaced with canonical server content');
assert.equal(normalized.editor.value, canonical);
assert.equal(normalizedStorage.size, 0, 'canonical normalization alone does not leave a dirty draft');
holdNormalizedSave = true;
normalized.edit('#!name=Another User Name\n[Rule]\nDOMAIN,two.invalid,DIRECT');
const normalizingSave = normalized.controller.savePreview({ id: 'normalized' });
normalized.edit('#!name=Another User Name\n[Rule]\nDOMAIN,three.invalid,DIRECT');
completeNormalizedSave();
await normalizingSave;
holdNormalizedSave = false;
assert.match(normalized.controller.text, /three.invalid/);
assert.equal(normalized.controller.savedText, canonical);
assert.match(canonical, /Canonical Module[\s\S]*two.invalid/);
normalized = normalizedSession();
await normalized.controller.loadPreview('/api/modules/normalized/preview', true);
assert.doesNotMatch(normalized.message.textContent, /服务器内容已变化/, 'normalization does not become a false upstream conflict on draft recovery');
normalized.controller.recoverDraft();
assert.match(normalized.controller.text, /three.invalid/);
assert.equal(normalized.controller.savedText, canonical, 'restored pending input retains the actual canonical baseline');
await normalized.controller.savePreview({ id: 'normalized' });
assert.equal(normalized.controller.savedText, canonical);
assert.equal(normalizedStorage.size, 0);
console.log('Canonical metadata save and draft recovery tests passed');

let restoreServer = 'original manual content';
let restoreVersion = '"restore-one"';
const restoreRequests = [];
let allowRestore = true;
const restoreEditor = { value: '', addEventListener(type, callback) { this[type] = callback; } };
const restoreMessage = { textContent: '' };
const guardedRestore = previewHelpers.createPreviewController({
  document: { querySelector: selector => selector === '#code-editor' ? restoreEditor : selector === '#preview-message' ? restoreMessage : null },
  storage: { getItem: () => null, setItem() {}, removeItem() {} },
  askConfirmation: async () => allowRestore,
  api: async (_path, options = {}) => {
    if (options.method === 'DELETE') {
      restoreRequests.push(options.headers['If-Match']);
      if (options.headers['If-Match'] !== restoreVersion) throw Object.assign(new Error('changed'), { status: 412 });
      restoreServer = 'converted content'; restoreVersion = '"restored"';
    }
    return { body: restoreServer, etag: restoreVersion };
  }
});
await guardedRestore.loadPreview('/api/modules/restore/preview', true);
restoreEditor.value = 'unsaved browser draft'; restoreEditor.input();
allowRestore = false;
await guardedRestore.restorePreview({ id: 'restore', name: 'Restore' });
assert.equal(restoreRequests.length, 0);
allowRestore = true; restoreServer = 'other client changed'; restoreVersion = '"restore-two"';
await guardedRestore.restorePreview({ id: 'restore', name: 'Restore' });
assert.deepEqual(restoreRequests, ['"restore-one"']);
assert.equal(restoreServer, 'other client changed');
assert.equal(guardedRestore.text, 'unsaved browser draft');
assert.match(restoreMessage.textContent, /服务器内容已变化/);
await guardedRestore.restorePreview({ id: 'restore', name: 'Restore' });
assert.deepEqual(restoreRequests, ['"restore-one"', '"restore-two"']);
assert.equal(guardedRestore.text, 'converted content');
assert.equal(guardedRestore.savedText, 'converted content');
console.log('Conditional conversion restore tests passed');

restoreServer = 'another concurrent clean-page change'; restoreVersion = '"restore-three"';
await guardedRestore.restorePreview({ id: 'restore', name: 'Restore' });
assert.equal(guardedRestore.text, 'converted content');
assert.match(restoreMessage.textContent, /服务器内容已变化/, 'a stale restore on an otherwise clean editor keeps comparison guidance visible');
