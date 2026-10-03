import assert from 'node:assert/strict';
import { editorHelpers, logic, markup, detailHelpers } from './harness.mjs';
const fields = { refreshIntervalMinutes: { value: '' }, customRefreshIntervalMinutes: { value: '' } };
const row = { hidden: true };
const editor = editorHelpers.createModuleEditorController({ ui: { moduleForm: { elements: fields } }, logic, markup, document: { querySelector: selector => selector === '#custom-refresh-row' ? row : null } });
for (const minutes of [null, 0, 5, 15, 60, 360, 1440, 37, 10080]) {
  editor.populateModuleForm({ name: 'Refresh', refreshIntervalMinutes: minutes });
  const collected = editor.collectModuleFields();
  assert.equal(collected.refreshIntervalMinutes, minutes);
  assert.equal(logic.moduleEditorPayload(collected).refreshIntervalMinutes, minutes);
  assert.equal(row.hidden, ![37, 10080].includes(minutes));
}
fields.refreshIntervalMinutes.value = '';
editor.updateRefreshPolicy();
assert.equal(logic.moduleEditorPayload(editor.collectModuleFields()).refreshIntervalMinutes, null, 'reset to inherited is an explicit JSON null');
assert.equal(fields.customRefreshIntervalMinutes.disabled, true);
fields.refreshIntervalMinutes.value = 'custom';
editor.updateRefreshPolicy();
assert.equal(fields.customRefreshIntervalMinutes.required, true);
for (const invalid of ['', '0', '-1', '1.5', '10081', 'NaN']) {
  fields.customRefreshIntervalMinutes.value = invalid;
  assert.equal(logic.validateModuleEditorFields(editor.collectModuleFields()).field, 'customRefreshIntervalMinutes');
}
fields.customRefreshIntervalMinutes.value = '1';
assert.equal(logic.validateModuleEditorFields(editor.collectModuleFields()), null);
editor.populateModuleForm({ refreshIntervalMinutes: 'future-policy', futureField: { enabled: true } });
assert.equal(fields.refreshIntervalMinutes.value, 'unchanged');
assert.equal(Object.hasOwn(editor.collectModuleFields(), 'refreshIntervalMinutes'), false, 'unrecognized stored policy is preserved unless explicitly changed');
assert.equal(Object.hasOwn(logic.moduleEditorPayload({}), 'refreshIntervalMinutes'), false, 'older callers omitting the field remain compatible');
assert.equal(logic.refreshIntervalTitle(0), '仅手动刷新');
assert.equal(logic.refreshIntervalTitle(37), '每 37 分钟');
assert.equal(logic.refreshIntervalTitle(null), '继承全局');
const deadline = new Date(Date.now() + 60000).toISOString();
const module = { id: 'cooling', name: 'Cooling', serverRetryAfter: deadline, nextRetryAt: deadline, consecutiveFailureCount: 3, refreshIntervalMinutes: 0 };
assert.ok(logic.serverCooldownRemaining(module) > 0);
assert.equal(logic.serverCooldownRemaining(module, new Date(deadline).valueOf()), 0);
assert.equal(logic.serverCooldownRemaining({ serverRetryAfter: 'unknown' }), 0);
assert.match(markup.moduleHeaderMarkup(module), /data-action="update-module"[^>]*disabled/);
assert.match(markup.moduleHeaderMarkup(module), /服务器冷却中/);
const details = markup.moduleDetailMarkup(module, { combined: { isEnabled: false } });
assert.match(details, /下次重试/);
assert.match(details, /服务器冷却/);
assert.match(details, /3 次；手动更新可跳过普通退避/);
assert.match(details, /仅手动刷新/);
assert.equal(logic.metadataRowPresenceChanged(module, { ...module, consecutiveFailureCount: 4 }), true);
let callback;
const heading = { outerHTML: '' };
const detail = { innerHTML: '', querySelector: selector => selector === '.module-heading' ? heading : null, querySelectorAll: () => [] };
let scheduled = 0;
const controller = detailHelpers.createDetailController({
  ui: { detail, mobileTitle: {} }, logic, markup, previewController: { deactivate() {} },
  api: async () => ({}), getState: () => ({ modules: [module], combined: {}, activity: {} }), getSelectedID: () => module.id,
  setTimeout(handler, delay) { callback = handler; scheduled += 1; assert.ok(delay > 0 && delay <= 61000); return scheduled; }, clearTimeout() {}
});
controller.renderDetail(false);
assert.equal(scheduled, 1);
module.serverRetryAfter = new Date(Date.now() - 1).toISOString();
callback();
assert.doesNotMatch(heading.outerHTML, /data-action="update-module"[^>]*disabled/, 'manual update unlocks when server cooldown expires without requiring a new SSE event');
assert.equal(scheduled, 1, 'expired cooldown does not create a polling timer');
console.log('Refresh policy and server cooldown tests passed');
