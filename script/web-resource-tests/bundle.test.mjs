import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { verifyWebBundle } from '../verify_web_bundle.mjs';

for (const nested of [false, true]) {
  const app = mkdtempSync(join(tmpdir(), 'surge-web-bundle-'));
  try {
    const root = join(app, 'Contents', 'Resources', ...(nested ? ['WebResources'] : []));
    mkdirSync(root, { recursive: true });
    writeFileSync(join(root, 'index.html'), '<link rel="stylesheet" href="/app.css?v=2"><script src="/app.js?v=2"></script>');
    writeFileSync(join(root, 'app.css'), 'body { color: #222; }');
    assert.throws(() => verifyWebBundle(app), /Missing bundled Web resource: app.js/);
    writeFileSync(join(root, 'app.js'), 'const ready = true;');
    assert.deepEqual(verifyWebBundle(app), { files: 2, scripts: 1 });
    writeFileSync(join(root, 'app.js'), 'const = ;');
    assert.throws(() => verifyWebBundle(app), SyntaxError);
  } finally { rmSync(app, { recursive: true, force: true }); }
}
