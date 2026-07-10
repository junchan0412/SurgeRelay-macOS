import assert from 'node:assert/strict';
import { activityHelpers, logic, sidebarHelpers } from './harness.mjs';

const sidebarLabel = { textContent: '' };
const sidebarToggle = { checked: false };
const sidebarRow = {
  classList: {
    disabled: null,
    toggle(name, value) {
      if (name === 'disabled') this.disabled = value;
    }
  },
  querySelector(selector) {
    return selector === '[data-module-toggle]' ? sidebarToggle : null;
  }
};
const sidebarUI = {
  search: { value: '' },
  filterRow: { hidden: true },
  failureFilter: {
    hidden: true,
    attrs: {},
    setAttribute(name, value) { this.attrs[name] = value; },
    querySelector: () => sidebarLabel
  },
  summaryRow: {
    hidden: true,
    classList: {
      selected: null,
      toggle(name, value) {
        if (name === 'selected') this.selected = value;
      }
    }
  },
  summarySubtitle: { textContent: '' },
  list: {
    innerHTML: '',
    querySelector: selector => selector.includes('module-1') ? sidebarRow : null
  }
};
let sidebarState = {
  combined: { isEnabled: true, enabledCount: 1 },
  modules: [{
    id: 'module-1',
    name: 'Failed Module',
    sourceURL: 'https://example.com/failed.conf',
    sourceFormatTitle: 'Quantumult X',
    relationshipSummary: 'GitHub 模块',
    state: 'failed',
    stateTitle: '失败',
    lastError: '原始链接返回 404',
    isEnabled: false,
    publishesStandalone: true
  }]
};
let sidebarFailuresOnly = false;
const sidebarController = sidebarHelpers.createSidebarController({
  ui: sidebarUI,
  getState: () => sidebarState,
  getSelectedID: () => 'combined',
  getFailuresOnly: () => sidebarFailuresOnly,
  setFailuresOnly: value => { sidebarFailuresOnly = value; }
});
sidebarController.render();
assert.equal(sidebarUI.filterRow.hidden, false);
assert.equal(sidebarUI.failureFilter.attrs['aria-pressed'], 'false');
assert.equal(sidebarUI.summaryRow.classList.selected, true);
assert.match(sidebarUI.list.innerHTML, /Failed Module/);
sidebarController.toggleFailuresOnly();
assert.equal(sidebarFailuresOnly, true);
assert.equal(sidebarUI.failureFilter.attrs['aria-pressed'], 'true');
sidebarState = {
  combined: { isEnabled: true, enabledCount: 1 },
  modules: [{ ...sidebarState.modules[0], isEnabled: true }]
};
sidebarController.patchLive();
assert.equal(sidebarToggle.checked, true);
assert.equal(sidebarRow.classList.disabled, false);

const activityCancelLabel = { textContent: '' };
const activityUI = {
  status: { textContent: '' },
  refresh: {
    disabled: false,
    title: '',
    attrs: {},
    setAttribute(name, value) { this.attrs[name] = value; }
  },
  percent: { textContent: '' },
  progressTrack: { hidden: true },
  progressFill: { style: { width: '' } },
  cancelActivity: {
    hidden: true,
    disabled: false,
    querySelector: () => activityCancelLabel
  },
  latestUpdate: { textContent: '' }
};
let activityState = {
  combined: { lastUpdatedAt: '2026-07-05T12:34:00Z' },
  activity: {
    title: '更新模块',
    status: '正在更新',
    isWorking: true,
    progress: 0.42,
    canCancel: true,
    kind: 'updatingModules',
    canStartUpdate: false,
    updateBlockedReason: '正在执行任务'
  }
};
const activityController = activityHelpers.createActivityController({
  ui: activityUI,
  getState: () => activityState
});
activityController.render();
assert.match(activityUI.status.textContent, /更新模块/);
assert.equal(activityUI.refresh.disabled, true);
assert.equal(activityUI.refresh.attrs['aria-label'], '无法更新：正在执行任务');
assert.equal(activityUI.cancelActivity.hidden, false);
assert.equal(activityUI.cancelActivity.disabled, false);
assert.equal(activityCancelLabel.textContent, '取消');
assert.equal(activityUI.percent.textContent, '42%');
assert.equal(activityUI.progressTrack.hidden, false);
assert.equal(activityUI.progressFill.style.width, '42%');
assert.match(activityUI.latestUpdate.textContent, /2026/);
activityState = {
  combined: { lastUpdatedAt: null },
  activity: {
    title: '',
    status: '准备就绪',
    kind: 'idle',
    isWorking: false,
    canStartUpdate: true
  }
};
activityController.render();
assert.equal(activityUI.refresh.disabled, false);
assert.equal(activityUI.cancelActivity.hidden, true);
assert.equal(activityUI.percent.textContent, '');
assert.equal(activityUI.progressTrack.hidden, true);
assert.equal(activityUI.latestUpdate.textContent, '尚未更新');
assert.deepEqual(
  JSON.parse(JSON.stringify(logic.activityPresentation({
    kind: 'idle',
    status: '',
    title: '',
    canStartUpdate: true,
    canCancel: false,
    isWorking: false,
    progress: null
  }))),
  {
    statusText: '准备就绪',
    refreshDisabled: false,
    refreshTitle: '更新全部',
    refreshAriaLabel: '更新全部',
    showCancel: false,
    canCancel: false,
    cancelLabel: '取消',
    progressPercent: null,
    progressVisible: false,
    progressWidth: '0%'
  }
);
assert.deepEqual(
  JSON.parse(JSON.stringify(logic.activityPresentation({
    kind: 'idle',
    status: '等待本地模块根目录',
    canStartUpdate: false,
    updateBlockedReason: '请先配置本地模块根目录',
    automaticPublishRunsAt: '2026-07-04T12:00:00Z'
  }, {
    formatAutomaticPublish: value => `formatted ${value}`
  }))),
  {
    statusText: '等待本地模块根目录 · 自动发布 formatted 2026-07-04T12:00:00Z',
    refreshDisabled: true,
    refreshTitle: '请先配置本地模块根目录',
    refreshAriaLabel: '无法更新：请先配置本地模块根目录',
    showCancel: false,
    canCancel: false,
    cancelLabel: '取消',
    progressPercent: null,
    progressVisible: false,
    progressWidth: '0%'
  }
);
assert.deepEqual(
  JSON.parse(JSON.stringify(logic.activityPresentation({
    kind: 'updating',
    title: '更新',
    status: '正在转换模块',
    canStartUpdate: false,
    canCancel: true,
    cancellationRequested: false,
    isWorking: true,
    progress: 1.4
  }))),
  {
    statusText: '更新 · 正在转换模块',
    refreshDisabled: true,
    refreshTitle: '当前无法开始更新',
    refreshAriaLabel: '无法更新：当前无法开始更新',
    showCancel: true,
    canCancel: true,
    cancelLabel: '取消',
    progressPercent: 100,
    progressVisible: true,
    progressWidth: '100%'
  }
);
assert.equal(
  logic.activityPresentation({
    kind: 'updating',
    canCancel: true,
    cancellationRequested: true,
    isWorking: true,
    progress: 0.42
  }).cancelLabel,
  '正在取消'
);

assert.equal(
  logic.moduleSubtitle({
    relationshipSummary: '远程模块 · 自写模块',
    category: 'Ads',
    outputFolder: 'Folder',
    publishesStandalone: false,
    state: 'current'
  }),
  '远程模块 · 自写模块 · Ads · Folder · 不发布独立模块'
);

assert.equal(
  logic.moduleSubtitle({
    sourceFormatTitle: 'Surge 模块',
    publishesStandalone: true,
    state: 'failed',
    lastError: '原始链接返回 404\n请检查路径'
  }),
  '更新失败：原始链接返回 404'
);
