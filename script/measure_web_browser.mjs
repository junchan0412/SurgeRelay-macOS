import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import os from 'node:os';
import { startBrowserFixture } from './browser_fixture_server.mjs';

const { chromium } = await import(process.env.SURGE_RELAY_PLAYWRIGHT_MODULE || 'playwright');
const phase = process.argv[2] || 'all';
await mkdir('docs/performance', { recursive: true });
const fixture = await startBrowserFixture();
const browser = await chromium.launch({ channel: 'chrome', headless: process.env.SURGE_RELAY_HEADED !== '1', args: ['--enable-precise-memory-info'] });
const report = {
  timestamp: new Date().toISOString(), phase,
  environment: { platform: os.platform(), release: os.release(), cpu: os.cpus()[0].model, cpuCount: os.cpus().length, ramBytes: os.totalmem(), node: process.version, browser: browser.version(), headless: process.env.SURGE_RELAY_HEADED !== '1', macOS: execFileSync('sw_vers', ['-productVersion'], { encoding: 'utf8' }).trim() },
  method: 'Current WebResources in installed Chrome; isolated 127.0.0.1 ephemeral HTTP fixture and in-memory API. No real Surge/GitHub backend. Filter timing is synchronous DOM input dispatch through two requestAnimationFrame callbacks (next paint opportunity). Each 30-sample batch includes alternating restrictive and full-list searches. Scroll is scripted real scrollTop over 180 rAF frames. Longtasks observed at browser main thread. JS heap is Chromium performance.memory, not whole-process RSS.',
  acceptance: [], measurements: [], errors: []
};
const contexts = [];
async function open(viewport = { width: 1280, height: 900 }) {
  const context = await browser.newContext({ viewport }); contexts.push(context);
  const page = await context.newPage();
  page.on('pageerror', error => report.errors.push(error.message));
  await page.route('**/*', route => new URL(route.request().url()).origin === fixture.origin ? route.continue() : route.abort());
  await page.goto(fixture.origin);
  await page.locator('.module-row').first().waitFor();
  return page;
}
const record = (name, details = {}) => report.acceptance.push({ name, passed: true, ...details });
try {
  if (phase !== 'performance') {
    fixture.setCount(100);
    const page = await open();
    await page.locator('.module-open').first().click();
    await page.locator('[data-action="edit"]').click();
    await page.locator('[name="storageLocation"]').selectOption('both');
    await page.locator('[name="outputFolder"]').selectOption('Local');
    await page.locator('#save-module-button').click();
    await page.waitForFunction(() => !document.querySelector('#module-dialog').open);
    const mutation = fixture.requests.findLast(request => request.payload);
    assert.deepEqual(mutation.payload.storageTargets, ['local', 'gitHub']);
    assert.equal(mutation.payload.storageLocation, 'local');
    record('dual destination editor submits both targets', { payload: mutation.payload.storageTargets });

    await page.locator('[data-action="tab-preview"]').click();
    const editor = page.locator('#code-editor');
    await editor.waitFor();
    await page.waitForFunction(() => !document.querySelector('#code-editor').disabled);
    try {
      await editor.fill('small input probe', { timeout: 3000 });
      record('small textarea input through Playwright fill');
    } catch (error) {
      report.inputProbe = { passed: false, error: error.message.slice(0, 500), state: await editor.evaluate(element => ({ inertAncestor: element.closest('[inert]')?.id, visible: element.checkVisibility(), visibility: getComputedStyle(element).visibility, readOnly: element.readOnly, ariaDisabled: element.closest('[aria-disabled="true"]')?.id })) };
    }
    const bigDraft = '# large fixture\n' + 'DOMAIN,example.invalid,DIRECT\n'.repeat(190000);
    report.acceptance.push({ name: 'preview editor geometry', geometry: await editor.evaluate(element => ({ rect: element.getBoundingClientRect().toJSON(), hidden: element.hidden, display: getComputedStyle(element).display, disabled: element.disabled })) });
    await editor.evaluate((element, value) => { element.value = value; element.dispatchEvent(new Event('input', { bubbles: true })); }, bigDraft);
    await page.evaluate(() => previewController.flushDrafts());
    await page.reload();
    await page.locator('.module-open').first().click();
    await page.locator('[data-action="tab-preview"]').click();
    await page.locator('[data-action="recover-draft"]').waitFor({ state: 'visible' });
    await page.locator('[data-action="recover-draft"]').click();
    assert.equal(await page.locator('#code-editor').inputValue(), bigDraft);
    record('IndexedDB restores a draft larger than 5 MiB after real page reload', { utf8Bytes: Buffer.byteLength(bigDraft), dataEntry: 'DOM value assignment + input event; not a large-file typing benchmark' });

    await page.locator('#code-editor').evaluate(element => { element.value = 'my concurrent edit'; element.dispatchEvent(new Event('input', { bubbles: true })); });
    fixture.setContent('module-0', 'other client wrote this');
    await page.locator('[data-action="save-preview"]').click();
    await page.locator('[data-action="compare-preview"]').waitFor({ state: 'visible' });
    assert.equal(fixture.content('module-0'), 'other client wrote this');
    assert.equal(await page.locator('#code-editor').inputValue(), 'my concurrent edit');
    await page.locator('[data-action="compare-preview"]').click();
    assert.equal(await page.locator('#server-preview').textContent(), 'other client wrote this');
    await page.locator('[data-action="save-preview"]').click();
    await page.locator('#confirm-accept').click();
    await page.waitForFunction(() => document.querySelector('#preview-status').textContent === '已保存');
    assert.equal(fixture.content('module-0'), 'my concurrent edit');
    record('ETag collision preserves draft, exposes server content, confirmed conditional retry saves');

    const mobile = await open({ width: 390, height: 844 });
    await mobile.locator('#add-button').click();
    await mobile.emulateMedia({ reducedMotion: 'reduce' });
    await mobile.waitForTimeout(100);
    await mobile.locator('#advanced-master').click();
    await mobile.locator('.option-group > summary').first().click();
    await mobile.waitForTimeout(50);
    const reduced = await mobile.evaluate(() => ({ open: document.querySelector('.option-group').open, reducedMedia: matchMedia('(prefers-reduced-motion: reduce)').matches, running: document.getAnimations().filter(animation => animation.playState === 'running').map(animation => ({ duration: animation.effect?.getTiming().duration, target: animation.effect?.target?.className, type: animation.constructor.name })) }));
    assert.equal(reduced.open, true);
    report.reducedMotionObservation = reduced;
    assert.equal(reduced.running.some(animation => animation.duration > 1), false);
    record('Reduce Motion suppresses WAAPI and CSS motion in actual Chromium', reduced);
    await mobile.emulateMedia({ reducedMotion: 'no-preference' });
    await mobile.evaluate(() => { for (let i = 0; i < 7; i += 1) document.querySelector('.option-group > summary').click(); });
    await mobile.waitForTimeout(350);
    assert.equal(await mobile.locator('.option-group').first().evaluate(element => element.open), false);
    await mobile.evaluate(() => { for (let i = 0; i < 8; i += 1) document.querySelector('#advanced-master').click(); });
    await mobile.waitForTimeout(400);
    assert.equal(await mobile.locator('#module-dialog').evaluate(element => element.style.height), '');
    await mobile.evaluate(() => { const dialog = document.querySelector('#module-dialog'); closeDialog(dialog); openDialog(dialog); });
    await mobile.waitForTimeout(250);
    assert.equal(await mobile.locator('#module-dialog').evaluate(element => element.open), true);
    record('rapid accordion and dialog reversal settles at newest requested state');
    await mobile.evaluate(() => closeDialog(document.querySelector('#module-dialog')));
    await mobile.waitForTimeout(250);
    const overflow = await mobile.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
    assert.equal(overflow, false);
    record('390 px mobile viewport has no horizontal overflow');
    await writeFile('docs/performance/web-browser-accessibility-snapshot.txt', await page.locator('body').ariaSnapshot());
    await Promise.all(contexts.splice(0).map(context => context.close()));
  }
  if (phase !== 'acceptance') {
    for (const count of [100, 1000, 5000]) {
      fixture.setCount(count);
      const page = await open();
      await page.waitForTimeout(600);
      const result = await page.evaluate(async count => {
        const longTasks = [];
        const observer = new PerformanceObserver(list => longTasks.push(...list.getEntries().map(entry => ({ startTime: entry.startTime, duration: entry.duration }))));
        observer.observe({ type: 'longtask' });
        const frame = () => new Promise(resolve => requestAnimationFrame(resolve));
        const percentile = (values, fraction) => [...values].sort((a, b) => a - b)[Math.min(values.length - 1, Math.ceil(values.length * fraction) - 1)];
        const input = document.querySelector('#search-input');
        const filter = [];
        const synchronous = [];
        for (let i = 0; i < 34; i += 1) {
          await frame();
          const start = performance.now();
          input.value = i % 2 ? '' : '00009';
          input.dispatchEvent(new Event('input', { bubbles: true }));
          const end = performance.now();
          await frame(); await frame();
          if (i >= 4) { filter.push(performance.now() - start); synchronous.push(end - start); }
        }
        const navigation = document.querySelector('.module-navigation');
        const frames = [];
        let prior = await frame();
        for (let i = 0; i < 180; i += 1) {
          navigation.scrollTop = Math.max(0, navigation.scrollHeight - navigation.clientHeight) * (i / 179);
          const stamp = await frame(); frames.push(stamp - prior); prior = stamp;
        }
        await frame();
        observer.disconnect();
        return {
          count, renderedRows: document.querySelectorAll('.module-row').length,
          filterNextPaintMs: { p50: percentile(filter, .5), p95: percentile(filter, .95), max: Math.max(...filter), samples: filter },
          filterSynchronousMs: { p50: percentile(synchronous, .5), p95: percentile(synchronous, .95), max: Math.max(...synchronous) },
          scrollFrameIntervalsMs: { p50: percentile(frames, .5), p95: percentile(frames, .95), max: Math.max(...frames), over33ms: frames.filter(value => value > 33.34).length, samples: frames.length },
          longTasks: { count: longTasks.length, maxMs: Math.max(0, ...longTasks.map(entry => entry.duration)), totalMs: longTasks.reduce((sum, entry) => sum + entry.duration, 0), entries: longTasks },
          jsHeap: performance.memory ? { used: performance.memory.usedJSHeapSize, total: performance.memory.totalJSHeapSize, limit: performance.memory.jsHeapSizeLimit } : null,
          viewport: { width: innerWidth, height: innerHeight, devicePixelRatio }, userAgent: navigator.userAgent
        };
      }, count);
      report.measurements.push(result);
      process.stdout.write(`${count} modules: filter p95 ${result.filterNextPaintMs.p95.toFixed(1)} ms; scroll frame p95 ${result.scrollFrameIntervalsMs.p95.toFixed(1)} ms; ${result.longTasks.count} longtasks\n`);
      await Promise.all(contexts.splice(0).map(context => context.close()));
    }
  }
} catch (error) {
  report.failure = { message: error.message.slice(0, 2000), stack: error.stack.slice(0, 3000) };
  process.exitCode = 1;
} finally {
  await Promise.all(contexts.map(context => context.close()));
  await browser.close(); await fixture.close();
  await mkdir('docs/performance', { recursive: true });
  await writeFile(`docs/performance/web-browser-${phase}.json`, JSON.stringify(report, null, 2));
  process.stdout.write(JSON.stringify({ acceptance: report.acceptance, errors: report.errors, failure: report.failure }, null, 2) + '\n');
}
