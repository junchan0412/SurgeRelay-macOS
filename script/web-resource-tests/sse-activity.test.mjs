import assert from 'node:assert/strict';
import { stateHelpers } from './harness.mjs';
const flush = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const streams = [];
class Stream { constructor(url) { this.url = url; this.listeners = new Map(); streams.push(this); } addEventListener(type, callback) { this.listeners.set(type, callback); } close() { this.closed = true; } }
const visibility = new Map();
const document = { hidden: false, addEventListener: (type, callback) => visibility.set(type, callback), removeEventListener: type => visibility.delete(type) };
let currentWorkspace = 'A';
let delayedState = null;
const states = [], activities = [];
const controller = stateHelpers.createStateEventController({
  EventSource: Stream, document, getWorkspaceID: () => currentWorkspace,
  applyState(snapshot) { states.push(snapshot); return delayedState?.promise; },
  applyActivity(activity, context) { activities.push({ activity, context }); },
  loadState: async () => {}, setInterval: () => 1, clearInterval() {}, setTimeout: () => 1, clearTimeout() {}
});
const send = (stream, type, payload) => stream.listeners.get(type)({ data: JSON.stringify(payload) });
const state = id => ({ workspace: { id }, modules: [{ id: 'same' }], activity: { isWorking: true } });
const activity = (id, progress) => ({ workspaceID: id, activity: { isWorking: true, progress } });
controller.start();
let stream = streams.at(-1);
send(stream, 'activity', activity('A', .1));
assert.equal(activities.length, 0);
send(stream, 'state', state('A'));
assert.equal(activities.at(-1).activity.progress, .1, 'activity arriving before initial state waits for its workspace snapshot');
send(stream, 'activity', activity('A', .2));
assert.equal(states.length, 1, 'activity events never call the full-state path');
assert.equal(activities.at(-1).context.source, 'sse');
delayedState = deferred();
send(stream, 'state', state('A'));
send(stream, 'activity', activity('A', .3));
send(stream, 'activity', activity('A', .4));
assert.equal(activities.at(-1).activity.progress, .2);
delayedState.resolve(); await flush(); delayedState = null;
assert.equal(activities.at(-1).activity.progress, .4, 'slow state commit coalesces progress and applies the newest activity afterward');
delayedState = deferred();
send(stream, 'state', state('B'));
send(stream, 'activity', activity('A', .99));
send(stream, 'activity', activity('B', .5));
currentWorkspace = 'B'; delayedState.resolve(); await flush(); delayedState = null;
assert.equal(activities.at(-1).activity.progress, .5);
const beforeOldWorkspace = activities.length;
send(stream, 'activity', activity('A', .98));
assert.equal(activities.length, beforeOldWorkspace);
currentWorkspace = 'C';
send(stream, 'activity', activity('B', .8));
assert.equal(activities.length, beforeOldWorkspace, 'HTTP workspace changes also reject stale stream activity');
currentWorkspace = 'B'; delayedState = deferred();
send(stream, 'state', state('B')); send(stream, 'activity', activity('B', .7));
const retired = stream;
controller.close(); controller.start(); stream = streams.at(-1);
delayedState.resolve(); await flush(); delayedState = null;
send(retired, 'activity', activity('B', .9));
assert.equal(activities.length, beforeOldWorkspace, 'replaced streams and late state callbacks cannot flush old activity');
send(stream, 'state', state('B')); send(stream, 'activity', activity('B', .6));
assert.equal(activities.at(-1).activity.progress, .6);
document.hidden = true; visibility.get('visibilitychange')();
send(stream, 'activity', activity('B', 1));
assert.equal(activities.at(-1).activity.progress, .6);
document.hidden = false; visibility.get('visibilitychange')();
stream = streams.at(-1); send(stream, 'state', state('B'));
assert.equal(states.at(-1).workspace.id, 'B', 'state-only legacy streams still render after reconnect');
controller.dispose();

const intervals = new Map();
let nextTimer = 0;
let polls = 0;
const first = deferred(), second = deferred(), third = deferred();
const received = [];
let pollingWorkspace = 'A';
const polling = stateHelpers.createStateEventController({
  document: { hidden: false }, getWorkspaceID: () => pollingWorkspace, isWorking: () => true,
  applyState() {}, loadState: async () => {}, applyActivity: value => received.push(value),
  fetchActivity: () => [first, second, third][polls++].promise,
  setInterval: (callback, delay) => { const id = ++nextTimer; intervals.set(id, { callback, delay }); return id; }, clearInterval: id => intervals.delete(id)
});
const tick = () => [...intervals.values()].find(timer => timer.delay === 1000).callback();
polling.start(); tick(); await flush();
pollingWorkspace = 'B';
first.resolve({ progress: .1 }); await flush();
assert.equal(received.length, 0, 'a slow poll from the previous workspace is ignored');
tick(); await flush();
polling.close(); polling.start(); tick(); await flush();
assert.equal(polls, 3, 'restarted polling is not blocked by an old in-flight request');
second.resolve({ progress: .2 }); await flush();
tick(); await flush();
assert.equal(polls, 3, 'retired request cleanup cannot clear the new in-flight guard');
third.resolve({ progress: .3 }); await flush();
assert.equal(received.at(-1).progress, .3);
polling.close();
console.log('Split SSE activity ordering, reconnect and workspace tests passed');

let runtime = 'run-1';
const versionedStates = [], versionedActivity = [];
let pendingVersionedState = null;
const versioned = stateHelpers.createStateEventController({
  EventSource: Stream, eventsURL: '/api/events?client=web&activity=0', document: { hidden: false },
  getWorkspaceID: () => 'A', getRuntimeID: () => runtime,
  applyState: snapshot => { versionedStates.push(snapshot); return pendingVersionedState?.promise; },
  applyActivity: (value, metadata) => versionedActivity.push({ value, metadata }), loadState: async () => {},
  setInterval: () => 0, clearInterval() {}
});
versioned.start();
let versionStream = streams.at(-1);
assert.equal(versionStream.url, '/api/events?client=web&activity=1', 'capability negotiation preserves existing query parameters');
const versionState = (runtimeID, revision) => ({ ...state('A'), runtimeID, revision });
const versionActivity = (runtimeID, revision) => ({ ...activity('A', revision / 100), runtimeID, revision });
send(versionStream, 'state', versionState('run-1', 10));
send(versionStream, 'activity', versionActivity('run-1', 12));
send(versionStream, 'activity', versionActivity('run-1', 11));
assert.equal(versionedActivity.length, 1);
assert.equal(versionedActivity.at(-1).metadata.revision, 12);
send(versionStream, 'state', versionState('run-1', 11));
send(versionStream, 'activity', versionActivity('run-1', 12));
assert.equal(versionedActivity.length, 1, 'older or duplicate activity revisions are ignored');
runtime = 'run-2';
send(versionStream, 'state', versionState('run-2', 1));
send(versionStream, 'activity', versionActivity('run-1', 99));
send(versionStream, 'state', versionState('run-1', 100));
send(versionStream, 'activity', versionActivity('run-2', 2));
assert.equal(versionedStates.at(-1).runtimeID, 'run-2');
assert.equal(versionedActivity.at(-1).metadata.runtimeID, 'run-2');
assert.equal(versionedActivity.at(-1).metadata.revision, 2, 'new runtime resets revision ordering');
versioned.close(); runtime = 'run-3'; versioned.start(); versionStream = streams.at(-1);
pendingVersionedState = deferred();
send(versionStream, 'activity', versionActivity('run-3', 10));
send(versionStream, 'state', versionState('run-3', 5));
send(versionStream, 'activity', versionActivity('run-3', 8));
pendingVersionedState.resolve(); await flush();
assert.equal(versionedActivity.at(-1).metadata.revision, 10, 'initial out-of-order activity preserves the highest buffered revision');
versioned.close();
