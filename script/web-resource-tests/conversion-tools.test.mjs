import assert from 'node:assert/strict';
import { toolsHelpers, stateHelpers } from './harness.mjs';

let selectedID = 'tools';
let state = { activity: { isWorking: false } };
const nodes = new Map(['#tool-convert', '#tool-cancel', '#tool-status', '#tool-error', '#tool-result'].map(id => [id, { innerHTML: '', textContent: '', hidden: false, disabled: false }]));
const ui = { mobileTitle: {}, detail: { innerHTML: '', querySelector: selector => nodes.get(selector), addEventListener() {} } };
const requests = [];
const waiting = [];
const copied = [];
const downloads = [];
const tools = toolsHelpers.createToolsController({
  ui, getState: () => state, getSelectedID: () => selectedID,
  copyText: async text => copied.push(text), downloadResult: result => downloads.push(result),
  api: async (path, options) => { requests.push({ path, options }); if (path === '/api/cancel-work') return {}; return new Promise((resolve, reject) => waiting.push({ resolve, reject })); }
});
function input(name, value) {
  const element = { dataset: { toolField: name }, value, type: 'text' };
  tools.handleInput({ target: { closest: () => element } });
}
function click(action) { return tools.handleClick({ target: { closest: () => ({ dataset: { toolAction: action }, disabled: false }) } }); }

tools.switchWorkspace({ id: 'A' }, 'runtime-A');
tools.render();
assert.match(ui.detail.innerHTML, /转换工具/);
assert.match(ui.detail.innerHTML, /释放注释关键字/);
assert.doesNotMatch(ui.detail.innerHTML, /data-tool-field="wrapResponse"/);
input('kind', 'script');
assert.doesNotMatch(ui.detail.innerHTML, /data-tool-field="includeKeywords"|data-tool-field="noResolve"/);
assert.match(ui.detail.innerHTML, /脚本源客户端/);
assert.match(ui.detail.innerHTML, /data-tool-field="wrapResponse"/);
input('sourceFormat', 'surge');
assert.doesNotMatch(ui.detail.innerHTML, /data-tool-field="wrapResponse"/);
input('kind', 'ruleSet');
input('outputFormat', 'quantumultX');
assert.match(ui.detail.innerHTML, /规则策略/);
assert.doesNotMatch(ui.detail.innerHTML, /value="domainSet"/);
input('sourceText', 'DOMAIN-SUFFIX,example.com');
input('policy', 'DIRECT');
const first = tools.convert();
assert.equal(requests[0].path, '/api/tools/convert');
assert.equal(requests[0].options.json.policy, 'DIRECT');
assert.equal(requests[0].options.json.sourceText, 'DOMAIN-SUFFIX,example.com');
assert.equal(nodes.get('#tool-convert').disabled, true);
input('sourceText', 'DOMAIN-SUFFIX,new.example');
waiting[0].resolve({ content: 'old result', fileName: 'old.list', outputFormat: 'quantumultX', kind: 'ruleSet' });
await first;
assert.equal(tools.result, null, 'old response cannot overwrite newly edited input');
assert.equal(tools.draft.sourceText, 'DOMAIN-SUFFIX,new.example');
const second = tools.convert();
waiting[1].resolve({ content: 'new result <script>', fileName: 'Converted.list', outputFormat: 'quantumultX', kind: 'ruleSet' });
await second;
assert.match(nodes.get('#tool-result').innerHTML, /new result &lt;script&gt;/);
await click('copy'); await click('download');
assert.deepEqual(copied, ['new result <script>']);
assert.equal(downloads[0].fileName, 'Converted.list');
selectedID = 'overview'; tools.patchStatus(); selectedID = 'tools'; tools.render();
assert.equal(tools.draft.sourceText, 'DOMAIN-SUFFIX,new.example', 'navigation retains the current form');
assert.match(nodes.get('#tool-result').innerHTML, /new result &lt;script&gt;/);
const oldWorkspace = tools.convert();
tools.switchWorkspace({ id: 'B' }, 'runtime-B');
tools.render();
assert.equal(tools.draft.sourceText, '');
waiting[2].resolve({ content: 'workspace A result', fileName: 'A.list' });
await oldWorkspace;
assert.equal(tools.result, null, 'old workspace responses stay isolated');
input('sourceText', 'B input');
const oldRuntime = tools.convert();
tools.switchWorkspace({ id: 'B' }, 'new-runtime-B');
const newRuntime = tools.convert();
waiting[3].resolve({ content: 'old runtime', fileName: 'old.list' });
await oldRuntime;
assert.equal(tools.result, null);
assert.equal(nodes.get('#tool-convert').disabled, true, 'old request completion does not unlock the new request');
state = { activity: { isWorking: true, kind: 'convertingTool', canCancel: true } };
await click('cancel');
assert.equal(requests.at(-1).path, '/api/cancel-work');
waiting[4].reject(new Error('转换已取消。'));
await newRuntime;
assert.equal(nodes.get('#tool-error').textContent, '转换已取消。');
tools.switchWorkspace({ id: 'A' }, 'runtime-A');
assert.equal(tools.draft.sourceText, 'DOMAIN-SUFFIX,new.example', 'returning to a workspace restores its form');
assert.equal(stateHelpers.resolveInitialSelection({ modules: [] }, { requestedModuleID: 'tools' }).selectedID, 'tools');
assert.equal(stateHelpers.normalizeSelection({ modules: [] }, 'tools').selectedID, 'tools');
state = { activity: { isWorking: true } };
const beforeBusy = requests.length;
await tools.convert();
assert.equal(requests.length, beforeBusy, 'busy feedback prevents another conversion request');
console.log('Conversion tools navigation, draft, result and cancellation tests passed');
