// Loads every wallpaper headless (as the apps do: index.html + #options) and checks for JS errors,
// and that each settings block is valid and matches options the page actually reads.
// Run: node app/tests/wallpapers.test.mjs      (needs Playwright)
import { createRequire } from 'node:module';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
let chromium;
try { ({ chromium } = require('playwright')); } catch { ({ chromium } = require(join(process.execPath, '../../lib/node_modules/playwright'))); }
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../..');

let failures = 0;
const ok = (cond, msg) => { if (cond) console.log('  ok  ', msg); else { failures++; console.log('  FAIL', msg); } };

const dirs = readdirSync(ROOT).filter(d => d.startsWith('Wallpaper - ') && existsSync(join(ROOT, d, 'index.html'))).sort();
const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
for (const d of dirs) {
  const file = join(ROOT, d, 'index.html');
  const html = readFileSync(file, 'utf8');
  const m = html.match(/<script type="application\/json" id="wallpaper-settings">([\s\S]*?)<\/script>/);
  console.log(`\n[${d}]`);
  ok(!!m, 'has a settings block');
  if (!m) continue;
  let man;
  try { man = JSON.parse(m[1]); ok(true, 'settings block is valid JSON'); } catch (e) { ok(false, 'settings JSON: ' + e.message); continue; }
  for (const p of man.params) {
    const used = html.includes(`params.get('${p.key}')`) || html.includes(`params.has('${p.key}')`) || html.includes(`num('${p.key}'`);
    ok(used, `option #${p.key} is read by the page`);
    if (p.type === 'select' && p.default !== '') ok(p.options.some(o => o[0] === String(p.default)), `#${p.key} default is one of its options`);
    if (p.type === 'range') ok(p.default >= p.min && p.default <= p.max, `#${p.key} default within range`);
  }
  // Build a non-default hash the way the settings page does (first option / max), then load both ways.
  const parts = [];
  for (const p of man.params) {
    if (p.group === 'testing' || p.type === 'action') continue;
    if (p.type === 'range') parts.push(`${p.key}=${p.min}`);
    else if (p.type === 'select') { const o = p.options.find(o => o[0] !== String(p.default)); if (o) parts.push(`${p.key}=${encodeURIComponent(o[0])}`); }
  }
  for (const hash of ['', '#offline&' + parts.join('&')]) {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    // Keep the live-data wallpapers off the network.
    await page.route(/^https?:\/\//, r => r.abort());
    await page.goto(pathToFileURL(file).href + hash);
    await page.waitForTimeout(d.includes('Earth') ? 6000 : 2500);
    ok(errors.length === 0, `loads without errors ${hash ? 'with options ' + hash.slice(0, 60) : '(defaults)'}` + (errors.length ? ': ' + errors.slice(0, 2).join(' | ') : ''));
    await page.close();
  }
}
await browser.close();
console.log(failures ? `\n${failures} FAILED` : '\nall passed');
process.exit(failures ? 1 : 0);
