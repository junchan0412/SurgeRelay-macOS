import assert from 'node:assert/strict';
import { logic, markup, format, activityHelpers, detailHelpers } from './harness.mjs';
const stages = [
  { moduleID: 'one', moduleName: '<one>', stage: 'download', detail: '<remote>' },
  { moduleID: 'two', moduleName: 'Two', stage: 'download' },
  { moduleID: 'three', moduleName: 'Three', stage: 'conversion' },
  { moduleID: 'four', moduleName: 'Four', stage: 'cache' },
  { moduleID: 'five', moduleName: 'Hidden fifth', stage: 'publish' }
];
const summary = logic.activeStageSummary(stages);
assert.equal(summary.text, '下载 2 · 转换 1 · 缓存 1');
assert.doesNotMatch(summary.title, /Hidden fifth/);
assert.equal(logic.activeStageSummary().text, '');
const activity = { isWorking: true, kind: 'updatingModules', progress: .25, completedCount: 1, totalCount: 4 };
assert.deepEqual(logic.activityPresentation({ ...activity, activeStages: stages }), logic.activityPresentation(activity), 'stage counts never replace the completed-module percentage');
const ui = {
  status: {}, stages: { textContent: '' }, refresh: { setAttribute() {} }, percent: {}, progressTrack: {}, progressFill: { style: {} },
  cancelActivity: { querySelector: () => ({}) }, latestUpdate: {}
};
let state = { activity: { ...activity, activeStages: stages }, combined: {} };
const activityController = activityHelpers.createActivityController({ ui, getState: () => state });
activityController.render();
assert.equal(ui.percent.textContent, '1/4');
assert.equal(ui.progressFill.style.width, '25%');
assert.equal(ui.stages.textContent, summary.text);
assert.equal(ui.stages.title, summary.title, 'module names and details are assigned as plain title text');
state.activity = { ...activity, isWorking: false };
activityController.render();
assert.equal(ui.stages.hidden, true);
const metrics = [
  { stage: 'download', duration: 6, attempts: 2, failedAttempts: 1, result: 'completed', bytesRead: 4096, bytesWritten: 0 },
  { stage: 'conversion', duration: 6, attempts: 1, failedAttempts: 0, result: 'completed', bytesRead: null, includesDownload: true, isPartial: true, reason: '<img src=x onerror=alert(1)>' },
  { stage: 'cache', duration: .1, attempts: 1, failedAttempts: 0, result: 'skipped', reason: 'unchanged' },
  { stage: 'publish', duration: .5, attempts: 1, failedAttempts: 1, result: 'failed', reason: 'offline' }
];
assert.equal(format.stageMetricPresentation(metrics[0]).written, '0 字节');
assert.equal(format.stageMetricPresentation(metrics[1]).read, '未采集');
assert.equal(format.stageMetricPresentation(metrics[1]).written, '未采集');
const entry = { id: 'entry', moduleName: 'Metric Module', date: '2026-10-02T00:00:00Z', duration: 8, outcome: 'updated', message: 'done', stageMetrics: metrics };
const html = markup.historyMarkup([entry], { detailed: true });
assert.match(html, /<details class="stage-metrics"><summary>/);
assert.doesNotMatch(html, /<details[^>]*open/);
assert.match(html, /转换\/下载（未拆分）/);
assert.match(html, /部分测量/);
assert.match(html, /读取内容字节/);
assert.match(html, /不可相加作为总耗时/);
assert.match(html, /不代表 TLS 流量或物理 I\/O/);
assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
assert.doesNotMatch(html, /<img src=x/);
assert.doesNotMatch(markup.historyMarkup([{ ...entry, stageMetrics: undefined }], { detailed: true }), /class="stage-metrics"/);
assert.doesNotMatch(markup.historyMarkup([entry]), /class="stage-metrics"/, 'dashboard summaries do not expand metric payloads');
const copied = format.historyRecordText(entry);
assert.match(copied, /总耗时（记录）：8.00 秒/);
assert.doesNotMatch(copied, /总耗时（记录）：12/);
assert.match(copied, /转换\/下载（未拆分）.*部分测量/);
assert.match(copied, /读取内容字节：未采集；写入内容字节：未采集/);
assert.match(copied, /尝试 2 次；失败尝试 1 次/);
const detail = detailHelpers.createDetailController({
  ui: { detail: { innerHTML: '' }, mobileTitle: {} }, markup, logic, previewController: { deactivate() {} },
  getState: () => ({ workspace: { recentHistory: [entry], historyCount: 1 }, modules: [] }), getSelectedID: () => 'activity',
  api: async () => [entry]
});
detail.renderDetail(false);
await new Promise(resolve => setImmediate(resolve));
assert.equal(detail.historyRecordText(0), copied, 'copy uses full history API metrics');
assert.equal(detail.historyRecordText(-1), '');
console.log('Live stage counts and folded history metric tests passed');
