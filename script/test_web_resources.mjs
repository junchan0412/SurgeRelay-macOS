import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const logicSource = readFileSync(new URL('../SurgeRelay/WebResources/web-logic.js', import.meta.url), 'utf8');
const context = vm.createContext({ console, URL });
vm.runInContext(logicSource, context, { filename: 'web-logic.js' });

const logic = context.SurgeRelayWebLogic;
assert.ok(logic, 'web logic should install a global testable API');

assert.equal(
  logic.publishedRelativePathForDraft({
    name: 'YouTube Ads',
    sourceURL: 'https://example.com/plugin.lpx',
    storageLocation: 'gitHub',
    outputFolder: ' Ads / Video ',
    outputFileName: ''
  }),
  'Ads/Video/YouTube-Ads.sgmodule'
);

assert.equal(
  logic.publishedRelativePathForDraft({
    name: 'YouTube Ads',
    sourceURL: 'https://example.com/source.sgmodule',
    storageLocation: 'local',
    outputFolder: 'Ads',
    outputFileName: 'YouTube Ads.sgmodule'
  }),
  'Ads/YouTube Ads.sgmodule'
);

assert.equal(
  logic.outputPathNotice('Surge-Relay.sgmodule', true, { combinedFileName: 'Surge Relay' }).warning,
  true
);

assert.match(
  logic.outputPathNotice('Folder/Demo.sgmodule', true, {
    modules: [{ id: 'one', name: 'Demo', publishedRelativePath: 'Folder/Demo.sgmodule' }]
  }).message,
  /Demo/
);

assert.equal(
  logic.outputPathNotice('Folder/Demo.sgmodule', true, {
    modules: [{ id: 'one', name: 'Demo', publishedRelativePath: 'Folder/Demo.sgmodule' }],
    editingID: 'one'
  }),
  null
);

assert.equal(
  logic.outputPathNotice('Folder/Demo.sgmodule', false).message,
  '未开启独立发布时，不会写出这个独立模块文件。'
);

const signatureBase = {
  id: 'module-1',
  name: 'Demo',
  sourceURL: 'https://example.com/demo.sgmodule',
  effectiveOriginalSourceURL: 'https://example.com/demo.sgmodule',
  sourceFormatTitle: 'Surge 模块',
  outputFolder: 'Folder',
  publishedRelativePath: 'Folder/Demo.sgmodule',
  storageLocation: 'gitHub',
  storageLocationTitle: 'GitHub 模块',
  sourceOriginTitle: '远程 Surge 模块',
  relationshipSummary: 'GitHub 模块 · 远程 Surge 模块',
  localStorageRelativePath: '',
  iconURL: '',
  customIconURL: '',
  isEnabled: false,
  publishesStandalone: true,
  state: 'current',
  stateTitle: '已是最新',
  lastError: '',
  lastUpdatedAt: '2026-07-04T12:00:00Z',
  sourceCheckedAt: '2026-07-04T12:00:00Z',
  contentHash: 'abc',
  sourceContentHash: 'def',
  sourceETag: 'etag',
  sourceLastModified: 'date',
  conversionEngineRevision: 'rev'
};
assert.notEqual(
  logic.moduleListSignature(signatureBase),
  logic.moduleListSignature({ ...signatureBase, relationshipSummary: '本地模块 · 远程 Surge 模块' })
);
assert.notEqual(
  logic.moduleListSignature(signatureBase),
  logic.moduleListSignature({ ...signatureBase, lastError: '原始链接返回 404' })
);

assert.equal(
  logic.moduleMatchesSearch({
    ...signatureBase,
    outputFileName: 'Demo File.sgmodule',
    category: 'Ads',
    lastError: '原始链接返回 404',
    publishesStandalone: false
  }, ' demo file '),
  true
);
assert.equal(
  logic.moduleMatchesSearch({
    ...signatureBase,
    outputFileName: 'Demo File.sgmodule',
    category: 'Ads',
    lastError: '原始链接返回 404',
    publishesStandalone: false
  }, '原始链接返回 404'),
  true
);
assert.equal(
  logic.moduleMatchesSearch({
    ...signatureBase,
    outputFileName: 'Demo File.sgmodule',
    category: 'Ads',
    publishesStandalone: false
  }, '不发布独立模块'),
  true
);
assert.equal(
  logic.moduleMatchesSearch(signatureBase, '不存在的模块字段'),
  false
);

assert.equal(
  logic.moduleSubtitle({
    relationshipSummary: 'GitHub 模块 · 远程 Surge 模块',
    category: 'Ads',
    outputFolder: 'Folder',
    publishesStandalone: false,
    state: 'current'
  }),
  'GitHub 模块 · 远程 Surge 模块 · Ads · Folder · 不发布独立模块'
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

const indexHTML = readFileSync(new URL('../SurgeRelay/WebResources/index.html', import.meta.url), 'utf8');
const logicScriptIndex = indexHTML.indexOf('/web-logic.js');
const appScriptIndex = indexHTML.indexOf('/app.js');
assert.ok(logicScriptIndex >= 0, 'index should load web-logic.js');
assert.ok(appScriptIndex > logicScriptIndex, 'web-logic.js must load before app.js');
assert.match(indexHTML, /name="storageLocation"/);
assert.match(indexHTML, /name="outputFolder"/);
assert.match(indexHTML, /id="output-path-preview"/);

console.log('Web resource behavior tests passed');
