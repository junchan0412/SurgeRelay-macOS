import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { startBrowserFixture } from './browser_fixture_server.mjs';
const { chromium } = await import(process.env.SURGE_RELAY_PLAYWRIGHT_MODULE || 'playwright');
const fixture = await startBrowserFixture(); fixture.setWorkspace('A');
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const report = { timestamp: new Date().toISOString(), browser: browser.version(), fixtureOnly: true, checks: [], pageErrors: [] };
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  page.on('pageerror', error => report.pageErrors.push(error.message));
  await page.route('**/*', route => new URL(route.request().url()).origin === fixture.origin ? route.continue() : route.abort());
  await page.goto(`${fixture.origin}/__fixture/blank`);
  await page.evaluate(async () => {
    const scope = `surge-relay:drafts:v1:${location.origin}`, path = '/api/modules/module-0/preview';
    localStorage.setItem(scope, JSON.stringify([[path, { text: 'origin local draft', savedText: 'old baseline', updatedAt: 1 }]]));
    await new Promise((resolve, reject) => {
      const request = indexedDB.open('SurgeRelayBrowserDrafts', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('drafts', { keyPath: 'key' });
      request.onerror = reject;
      request.onsuccess = () => {
        const db = request.result, transaction = db.transaction('drafts', 'readwrite');
        transaction.objectStore('drafts').put({ key: `${scope}:${path}`, scope, path, text: 'origin IndexedDB draft', savedText: 'old baseline', updatedAt: 2 });
        transaction.oncomplete = () => { db.close(); resolve(); }; transaction.onerror = reject;
      };
    });
  });
  await page.goto(fixture.origin);
  await page.waitForFunction(() => state?.workspace?.id === 'A');
  const openPreview = async () => {
    await page.locator('.module-open').first().click();
    await page.locator('[data-action="tab-preview"]').click();
    await page.waitForFunction(() => document.querySelector('#preview-status')?.textContent !== '正在载入');
  };
  await openPreview();
  assert.equal(await page.locator('[data-action="recover-draft"]').isVisible(), false);
  await page.locator('#code-editor').fill('workspace A draft');
  await page.locator('[data-action="tab-info"]').click();
  await page.locator('[data-action="publish-selected"]').click();
  await page.locator('[data-operation="preview-selected"]').click();
  await page.locator('[data-operation="execute-publish"]').waitFor();
  fixture.setWorkspace('B');
  await page.waitForFunction(() => state?.workspace?.id === 'B');
  assert.equal(await page.locator('#operation-dialog').evaluate(element => element.open), false);
  assert.equal(await page.locator('.module-row').count(), 100);
  assert.equal(await page.evaluate(() => selectedID), 'overview');
  assert.match(await page.locator('#toast').textContent(), /已切换工作区/);
  await openPreview();
  assert.equal(await page.locator('[data-action="recover-draft"]').isVisible(), false);
  await page.locator('#code-editor').fill('workspace B draft');
  fixture.setWorkspace('A');
  await page.waitForFunction(() => state?.workspace?.id === 'A');
  await openPreview();
  await page.locator('[data-action="recover-draft"]').click();
  assert.equal(await page.locator('#code-editor').inputValue(), 'workspace A draft');
  report.checks.push('Live SSE workspace switch flushes old drafts, clears publication tickets/selection, rebuilds identical-ID sidebar and isolates A/B drafts');
  fixture.setWorkspace('legacy', true);
  await page.waitForFunction(() => state?.workspace?.id === 'legacy');
  await openPreview();
  await page.locator('[data-action="recover-draft"]').click();
  assert.equal(await page.locator('#code-editor').inputValue(), 'origin IndexedDB draft');
  report.checks.push('Only explicitly marked legacy default imports origin-only drafts during real IndexedDB v1-to-v2 migration');
  fixture.setWorkspace('B');
  await page.waitForFunction(() => state?.workspace?.id === 'B');
  await openPreview();
  await page.locator('[data-action="recover-draft"]').click();
  assert.equal(await page.locator('#code-editor').inputValue(), 'workspace B draft');
  await page.locator('[data-action="save-preview"]').click();
  await page.waitForFunction(() => document.querySelector('#preview-status').textContent === '已保存');
  assert.equal(fixture.requests.findLast(request => request.method === 'PUT' && request.path.endsWith('/preview')).workspace, 'B');
  const denied = await page.evaluate(() => fetch('/api/modules/module-0/preview', { method: 'PUT', headers: { 'X-Relay-Workspace': 'A' }, body: 'wrong scope' }).then(response => response.status));
  assert.equal(denied, 412);
  assert.equal(fixture.content('module-0'), 'workspace B draft');
  report.checks.push('Writes carry originating workspace header; mismatched workspace request is rejected by isolated fixture without changing data');
  assert.deepEqual(report.pageErrors, []);
  await context.close();
} catch (error) { report.failure = error.message.slice(0, 3000); process.exitCode = 1; }
finally {
  await browser.close(); await fixture.close();
  await mkdir('docs/performance', { recursive: true });
  await writeFile('docs/performance/web-workspace-acceptance.json', JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
}
