import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { startBrowserFixture } from './browser_fixture_server.mjs';
const { chromium } = await import(process.env.SURGE_RELAY_PLAYWRIGHT_MODULE || 'playwright');
const fixture = await startBrowserFixture();
fixture.setActivity({ isWorking: true, kind: 'updatingModules', progress: .25, completedCount: 1, totalCount: 4, activeStages: [{ moduleID: 'one', moduleName: '<one>', stage: 'download' }, { moduleID: 'two', moduleName: 'Two', stage: 'download' }, { moduleID: 'three', moduleName: 'Three', stage: 'conversion' }] });
fixture.setHistory([{ id: 'metrics', moduleName: 'Metric fixture', date: new Date().toISOString(), outcome: 'updated', duration: 8, message: 'Stage metrics fixture', stageMetrics: [{ stage: 'download', duration: 6, bytesRead: 4096, bytesWritten: 0, attempts: 2, failedAttempts: 1, result: 'completed' }, { stage: 'conversion', duration: 6, attempts: 1, failedAttempts: 0, result: 'completed', includesDownload: true, isPartial: true, reason: '<img id="stage-injection" src=x>' }] }]);
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const report = { timestamp: new Date().toISOString(), browser: browser.version(), fixtureOnly: true, checks: [], pageErrors: [] };
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  page.on('pageerror', error => report.pageErrors.push(error.message));
  await page.addInitScript(() => { Object.defineProperty(navigator, 'clipboard', { value: { writeText: async text => { window.fixtureCopied = text; } } }); });
  await page.route('**/*', route => new URL(route.request().url()).origin === fixture.origin ? route.continue() : route.abort());
  await page.goto(fixture.origin);
  await page.locator('#activity-stages').waitFor({ state: 'visible' });
  assert.equal(await page.locator('#activity-stages').textContent(), '下载 2 · 转换 1');
  assert.equal(await page.locator('#activity-percent').textContent(), '1/4');
  assert.equal(await page.locator('#progress-fill').evaluate(element => element.style.width), '25%');
  report.checks.push('Active stage counts are separate from unchanged completed-module count and percentage');
  await page.locator('#history-button').click();
  await page.locator('.stage-metrics').waitFor();
  assert.equal(await page.locator('.stage-metrics').evaluate(element => element.open), false);
  await page.locator('.stage-metrics summary').click();
  assert.match(await page.locator('.stage-metrics').textContent(), /转换\/下载（未拆分）/);
  assert.match(await page.locator('.stage-metrics').textContent(), /部分测量/);
  assert.match(await page.locator('.stage-metrics').textContent(), /未采集/);
  assert.match(await page.locator('.stage-metrics').textContent(), /内容字节，不代表 TLS 流量或物理 I\/O/);
  assert.equal(await page.locator('#stage-injection').count(), 0);
  await page.locator('[data-action="copy-history"]').click();
  const copied = await page.evaluate(() => window.fixtureCopied);
  assert.match(copied, /总耗时（记录）：8.00 秒/);
  assert.match(copied, /转换\/下载（未拆分）.*部分测量/);
  assert.match(copied, /读取内容字节：未采集/);
  report.checks.push('History details default closed, escape diagnostic text, distinguish unknown bytes and mixed/partial timing; copy includes metrics without summing parallel stages');
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  assert.deepEqual(report.pageErrors, []);
  await context.close();
} catch (error) { report.failure = error.message.slice(0, 3000); process.exitCode = 1; }
finally {
  await browser.close(); await fixture.close();
  await mkdir('docs/performance', { recursive: true });
  await writeFile('docs/performance/web-metrics-acceptance.json', JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
}
