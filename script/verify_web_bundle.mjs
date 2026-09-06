import { readFileSync, existsSync, statSync } from 'node:fs';
import { join, basename } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

export function verifyWebBundle(appPath) {
  const root = join(appPath, 'Contents', 'Resources');
  const resolveResource = relative => {
    const candidates = [join(root, 'WebResources', relative), join(root, basename(relative))];
    const file = candidates.find(path => existsSync(path) && statSync(path).isFile());
    if (!file) throw new Error(`Missing bundled Web resource: ${relative}`);
    return file;
  };
  const attribute = (tag, name) => tag.match(new RegExp(`\\b${name}\\s*=\\s*["']([^"']+)["']`, 'i'))?.[1];
  const html = readFileSync(resolveResource('index.html'), 'utf8');
  const checked = new Set();
  let scripts = 0;
  for (const match of html.matchAll(/<(script|link|img)\b[^>]*>/gi)) {
    const tag = match[0];
    const kind = match[1].toLowerCase();
    const reference = attribute(tag, kind === 'link' ? 'href' : 'src');
    if (!reference) continue;
    const url = new URL(reference, 'https://surge-relay.invalid');
    if (url.origin !== 'https://surge-relay.invalid') throw new Error(`Web assets must be bundled: ${reference}`);
    const relative = decodeURIComponent(url.pathname).replace(/^\/+/, '');
    if (relative.split('/').includes('..')) throw new Error(`Invalid bundled path: ${relative}`);
    const file = resolveResource(relative);
    checked.add(relative);
    if (kind === 'script') {
      new vm.Script(readFileSync(file, 'utf8'), { filename: relative });
      scripts += 1;
    }
  }
  if (!scripts) throw new Error('Bundled index.html has no application scripts');
  return { files: checked.size, scripts };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (!process.argv[2]) throw new Error('Usage: node script/verify_web_bundle.mjs <app bundle>');
  const result = verifyWebBundle(process.argv[2]);
  console.log(`ok: verified ${result.files} bundled Web assets and ${result.scripts} script syntaxes`);
}
