import assert from 'node:assert/strict';
import { stateHelpers, previewHelpers, markup } from './harness.mjs';

const flush = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const streams = [];
const timers = new Map();
const intervals = new Map();
let timerID = 0;
const events = new Map();
const doc = { hidden: false, addEventListener: (name, callback) => events.set(name, callback), removeEventListener: name => events.delete(name) };
class Stream {
  constructor() { this.listeners = new Map(); streams.push(this); }
  addEventListener(name, callback) { this.listeners.set(name, callback); }
  close() { this.closed = true; }
}
const received = [];
const session = deferred();
const controller = stateHelpers.createStateEventController({
  EventSource: Stream, document: doc,
  setTimeout: callback => { timers.set(++timerID, callback); return timerID; },
  clearTimeout: id => timers.delete(id),
  setInterval: callback => { intervals.set(++timerID, callback); return timerID; },
  clearInterval: id => intervals.delete(id),
  applyState: state => received.push(state), loadState: async () => {}, establishSession: () => session.promise,
  isWorking: () => true, fetchActivity: async () => ({}), applyActivity: () => {}
});
controller.start();
assert.equal(intervals.size, 0, 'a healthy SSE connection must not duplicate activity polling');
const oldStream = streams[0];
oldStream.onerror();
assert.equal(intervals.size, 1, 'activity polling covers reconnect gaps');
controller.close();
session.resolve();
await flush();
assert.equal(timers.size, 0, 'a late session response cannot reconnect after close');
assert.equal(intervals.size, 0, 'close clears every interval');
controller.start();
oldStream.listeners.get('state')({ data: '{"stale":true}' });
assert.equal(received.length, 0, 'events from replaced streams are ignored');
streams.at(-1).listeners.get('state')({ data: '{"fresh":true}' });
assert.equal(received.length, 1);
doc.hidden = true;
events.get('visibilitychange')();
assert.equal(streams.at(-1).closed, true);
assert.equal(controller.currentEventSource, null);
doc.hidden = false;
events.get('visibilitychange')();
assert.ok(controller.currentEventSource);
controller.dispose();
assert.equal(events.size, 0);

const slowActivity = deferred();
let fetchCount = 0;
let activityCount = 0;
const polling = stateHelpers.createStateEventController({
  document: { hidden: false },
  setInterval: (callback, delay) => { intervals.set(delay, callback); return delay; },
  clearInterval: id => intervals.delete(id),
  loadState: async () => {}, applyState: () => {}, isWorking: () => true,
  fetchActivity: () => { fetchCount++; return slowActivity.promise; },
  applyActivity: () => { activityCount++; }
});
polling.start();
intervals.get(1000)();
intervals.get(1000)();
await flush();
assert.equal(fetchCount, 1, 'slow requests never overlap');
polling.close();
slowActivity.resolve({ isWorking: true });
await flush();
assert.equal(activityCount, 0, 'late activity cannot mutate a closed controller');

function editor() { return { value: '', addEventListener(name, callback) { this[name] = callback; } }; }
let currentEditor = editor();
const save = { disabled: true };
const slow = deferred();
const saveResponse = deferred();
const preview = previewHelpers.createPreviewController({
  api: (path, options) => options?.method === 'PUT' ? saveResponse.promise : path.includes('/slow/') ? slow.promise : Promise.resolve(`content:${path}`),
  document: { querySelector: selector => selector === '#code-editor' ? currentEditor : selector.includes('save-preview') ? save : null },
  showToast() {}
});
const slowLoad = preview.loadPreview('/api/modules/slow/preview', true);
currentEditor = editor();
await preview.loadPreview('/api/modules/fast/preview', true);
slow.resolve('stale response');
await slowLoad;
assert.match(currentEditor.value, /fast/);
currentEditor.value = 'draft before saving';
currentEditor.input();
assert.equal(preview.hasUnsavedChanges, true);
currentEditor = editor();
await preview.loadPreview('/api/modules/other/preview', true);
currentEditor = editor();
await preview.loadPreview('/api/modules/fast/preview', true);
assert.equal(currentEditor.value, 'draft before saving', 'draft survives selection changes');
const saving = preview.savePreview({ id: 'fast' });
currentEditor.value = 'typed during save';
currentEditor.input();
saveResponse.resolve({ message: 'saved' });
await saving;
assert.equal(preview.savedText, 'draft before saving');
assert.equal(preview.text, 'typed during save');
assert.equal(save.disabled, false, 'new edits remain unsaved after the previous save response');
assert.equal(preview.hasUnsavedChanges, true);

const html = markup.workspaceMarkup({ modules: [{ id: 'x', name: '<script>unsafe</script>', state: 'failed', lastError: '<img src=x>', publishesStandalone: true }], activity: {}, moduleEditor: {} });
assert.match(html, /模块工作台/);
assert.match(html, /&lt;script&gt;/);
assert.doesNotMatch(html, /<script>/);
