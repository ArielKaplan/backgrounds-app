// Headless tests for app/shared/settings.html with a mock native bridge built from the real wallpaper files.
// Run: node app/tests/settings.test.mjs [--shots DIR]      (needs Playwright: npm i -g playwright)
import { createRequire } from 'node:module';
import { readFileSync, readdirSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
let chromium;
try { ({ chromium } = require('playwright')); } catch { ({ chromium } = require(join(process.execPath, '../../lib/node_modules/playwright'))); }

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../..');
const SHOTS = process.argv.includes('--shots') ? process.argv[process.argv.indexOf('--shots') + 1] : null;
if (SHOTS) mkdirSync(SHOTS, { recursive: true });

// Same extraction the native apps do.
function extractManifest(html) {
  const i = html.indexOf('id="wallpaper-settings"'); if (i < 0) return null;
  const a = html.indexOf('>', i) + 1, b = html.indexOf('</script>', a);
  return a > 0 && b > a ? html.slice(a, b) : null;
}
const wallpapers = readdirSync(ROOT).filter(d => d.startsWith('Wallpaper - ') && existsSync(join(ROOT, d, 'index.html'))).sort().map(d => {
  const html = readFileSync(join(ROOT, d, 'index.html'), 'utf8');
  return { id: d.replace(/^Wallpaper - /, ''), name: d.replace(/^Wallpaper - /, ''), manifest: extractManifest(html), header: html.slice(0, 16384) };
});
// Extra fixtures: no settings block (header fallback), and a broken settings block.
const aq = wallpapers.find(w => w.id === 'Aquarium');
wallpapers.push({ id: 'Zz Header Only', name: 'Zz Header Only', manifest: null, header: aq.header.replace(/<script type="application\/json"[\s\S]*?<\/script>/, '') });
wallpapers.push({ id: 'Zz Broken', name: 'Zz Broken', manifest: '{ "params": [ oops ] }', header: aq.header });

let failures = 0;
const ok = (cond, msg) => { if (cond) console.log('  ok  ', msg); else { failures++; console.log('  FAIL', msg); } };

const browser = await chromium.launch();
for (const scheme of ['light', 'dark']) {
  const ctx = await browser.newContext({ viewport: { width: 920, height: 680 }, colorScheme: scheme });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  await page.addInitScript(({ wallpapers }) => {
    const state = {
      platform: 'mac', version: '1.0.0', folder: '/Users/test/Pictures/Backgrounds', onBattery: false, launchAtLogin: false,
      screens: [{ id: 'A', name: 'Built-in Display', primary: true, width: 1512, height: 982 }, { id: 'B', name: 'LG UltraFine', primary: false, width: 2560, height: 1440 }],
      update: { current: '1.1.0', status: 'upToDate', latest: '1.1.0', notes: '', progress: 0, lastCheck: new Date(Date.now() - 3 * 3600e3).toISOString() },
      wallpapers, settings: { arrangement: 'same', wallpaper: 'Aquarium', screens: {}, params: {}, paused: false, pauseWhenCovered: true, pauseOnBattery: true },
    };
    window.__calls = [];
    window.__bridgeMock = msg => {
      window.__calls.push(JSON.parse(JSON.stringify(msg)));
      switch (msg.cmd) {
        case 'getState': return JSON.parse(JSON.stringify(state));
        case 'setSettings': state.settings = JSON.parse(JSON.stringify(msg.args.settings)); return JSON.parse(JSON.stringify(state));
        case 'setLaunchAtLogin': state.launchAtLogin = msg.args.enabled; return { enabled: state.launchAtLogin };
        case 'restoreBuiltins': return { added: [], state: JSON.parse(JSON.stringify(state)) };
        case 'checkForUpdates':
          state.update = { ...state.update, status: 'available', latest: '1.2.0', notes: '- Faster wallpapers\n- Bug fixes', lastCheck: new Date().toISOString() };
          return JSON.parse(JSON.stringify(state.update));
        case 'installUpdate':
          state.update = { ...state.update, status: 'downloading', progress: 40 };
          return JSON.parse(JSON.stringify(state.update));
        default: return null;
      }
    };
    window.__state = state;
  }, { wallpapers });
  await page.goto(pathToFileURL(join(ROOT, 'app/shared/settings.html')).href);
  await page.waitForSelector('.item');
  console.log(`\n[${scheme}]`);
  const lastSet = async () => page.evaluate(() => { const c = window.__calls.filter(c => c.cmd === 'setSettings').pop(); return c && c.args.settings; });
  const wait = ms => page.waitForTimeout(ms);

  ok(await page.locator('.item').count() === wallpapers.length, `lists all ${wallpapers.length} wallpapers`);
  ok((await page.textContent('#detail h2')) === 'Aquarium', 'selects the active wallpaper first');
  ok((await page.textContent('#status')) === 'Playing', 'status pill says Playing');
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/settings-${scheme}-aquarium.png` });

  // Range -> hash
  await page.locator('#p-pixels').fill('200');
  await wait(900);
  let s = await lastSet();
  ok(s && s.params.Aquarium.hash === 'pixels=200', `range writes hash (got ${s && s.params.Aquarium.hash})`);
  ok(await page.locator('.row.changed').count() === 1, 'changed row is marked');
  // Testing toggle
  await page.click('details.testing summary');
  await page.check('#p-debug', { force: true });
  await wait(100);
  s = await lastSet();
  ok(s.params.Aquarium.hash === 'pixels=200&debug', `toggle appends flag (got ${s.params.Aquarium.hash})`);
  await page.selectOption('#p-event', 'shark');
  await wait(100);
  s = await lastSet();
  ok(s.params.Aquarium.hash === 'pixels=200&event=shark&debug', `select writes value (got ${s.params.Aquarium.hash})`);
  // Setting back to default removes it
  await page.locator('#p-pixels').fill('240');
  await wait(900);
  s = await lastSet();
  ok(s.params.Aquarium.hash === 'event=shark&debug', `default value is omitted (got ${s.params.Aquarium.hash})`);
  // Reset
  await page.click('button:has-text("Reset to defaults")');
  await wait(100);
  s = await lastSet();
  ok(s.params.Aquarium.hash === '' && Object.keys(s.params.Aquarium.values).length === 0, 'reset clears values and hash');
  ok(await page.locator('button:has-text("Reset to defaults")').isDisabled(), 'reset disabled when at defaults');
  ok((await page.inputValue('#p-pixels')) === '240', 'controls show defaults after reset');

  // Text / number / time params with encoding (Earth + Room)
  await page.click('.item:has-text("Live Earth")');
  await page.fill('#p-home', '40.7,-74'); await page.press('#p-home', 'Enter');
  await wait(100);
  s = await lastSet();
  const eh = s.params.Earth.hash;
  ok(new URLSearchParams(eh).get('home') === '40.7,-74', `text param round-trips through URLSearchParams (hash ${eh})`);
  await page.click('.item:has-text("Cozy Room")');
  await page.fill('#p-time', '21:30');
  await page.fill('#p-lat', '40.7'); await page.locator('#p-lat').dispatchEvent('change');
  await wait(100);
  s = await lastSet();
  const rp = new URLSearchParams(s.params.Room.hash);
  ok(rp.get('time') === '21:30' && rp.get('lat') === '40.7', `time + number params (hash ${s.params.Room.hash})`);
  ok(!(await page.textContent('#detail')).includes('Changes apply to the desktop'), 'notes that a non-active wallpaper is not showing');
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/settings-${scheme}-room.png` });

  // Use as wallpaper
  await page.click('button:has-text("Use as wallpaper")');
  await wait(100);
  s = await lastSet();
  ok(s.wallpaper === 'Room', 'Use as wallpaper sets it');

  // Action param: needs two clicks
  await page.click('.item:has-text("Ant Farm")');
  await page.click('#p-reset');
  ok(!(await page.evaluate(() => window.__calls.some(c => c.cmd === 'reloadOnce'))), 'action not run on first click');
  await page.click('#p-reset');
  const once = await page.evaluate(() => window.__calls.find(c => c.cmd === 'reloadOnce'));
  ok(once && once.args.wallpaper === 'Ant Farm' && once.args.extra === 'reset', 'action runs reloadOnce on second click');

  // Header-only and broken fixtures
  await page.click('.item:has-text("Zz Header Only")');
  ok((await page.textContent('#detail')).includes('header comment'), 'header-only wallpaper falls back to header comment');
  ok(await page.locator('#p-pixels').count() === 1 && await page.locator('#p-debug').count() === 1, 'header fallback finds #pixels and #debug');
  await page.fill('#p-pixels', '150'); await page.press('#p-pixels', 'Enter');
  await wait(100);
  s = await lastSet();
  ok(s.params['Zz Header Only'].hash === 'pixels=150', `header fallback writes hash (${s.params['Zz Header Only'].hash})`);
  await page.click('.item:has-text("Zz Broken")');
  ok((await page.textContent('#detail')).includes('has an error'), 'broken settings block shows an error');

  // General tab: arrangement per screen
  await page.click('#tab-general');
  await page.click('#arrangement button[data-v="perScreen"]');
  await wait(100);
  s = await lastSet();
  ok(s.arrangement === 'perScreen' && s.screens.A === 'Room' && s.screens.B === 'Room', 'per-screen seeds each screen with the current wallpaper');
  await page.locator('#screenRows select').nth(1).selectOption('City');
  await wait(100);
  s = await lastSet();
  ok(s.screens.B === 'City' && s.screens.A === 'Room', 'per-screen choice for the second screen');
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/settings-${scheme}-general.png` });
  await page.click('#arrangement button[data-v="main"]');
  await wait(100);
  s = await lastSet();
  ok(s.arrangement === 'main', 'main-screen-only arrangement');
  await page.check('#g-login', { force: true });
  await wait(100);
  ok(await page.evaluate(() => window.__state.launchAtLogin === true), 'launch at login calls native');
  await page.uncheck('#g-battery', { force: true });
  await wait(100);
  s = await lastSet();
  ok(s.pauseOnBattery === false, 'pause-on-battery toggle saved');
  await page.click('#pause');
  await wait(100);
  s = await lastSet();
  ok(s.paused === true && (await page.textContent('#status')) === 'Paused', 'pause button');

  // Per-screen buttons in detail view
  await page.click('#arrangement button[data-v="perScreen"]');
  await page.click('#tab-wallpapers');
  await page.click('.item:has-text("Train")');
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/settings-${scheme}-perscreen.png` });
  ok(await page.locator('#detail .actions button:has-text("Built-in Display")').count() === 1, 'per-screen use buttons shown');

  // Updates
  await page.click('#tab-general');
  ok((await page.textContent('#u-current')) === '1.1.0', 'shows current version');
  ok((await page.textContent('#u-status')).includes('up to date'), 'shows up to date');
  ok((await page.textContent('#u-last')).includes('3 hours ago'), 'shows last check time');
  ok(!(await page.isVisible('#banner')), 'no banner when up to date');
  await page.click('#u-check');
  await wait(100);
  ok(await page.evaluate(() => window.__calls.some(c => c.cmd === 'checkForUpdates')), 'Check for Updates calls native');
  ok(await page.isVisible('#banner') && (await page.textContent('#banner-title')).includes('1.2.0'), 'banner shows the new version');
  ok((await page.textContent('#u-available')).includes('Faster wallpapers'), 'release notes shown');
  await page.click('#tab-wallpapers');
  ok(await page.isVisible('#banner'), 'banner visible on the Wallpapers tab too');
  await page.click('#banner-more');
  ok(await page.isVisible('#updates'), "What's new jumps to the Updates section");
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/settings-${scheme}-update.png` });
  await page.uncheck('#g-autoupdate', { force: true });
  await wait(100);
  s = await lastSet();
  ok(s.autoUpdateCheck === false, 'automatic update checks can be turned off');
  await page.click('#banner-install');
  await wait(100);
  ok(await page.evaluate(() => window.__calls.some(c => c.cmd === 'installUpdate')), 'Install & Restart calls native');
  ok((await page.textContent('#u-status')).includes('Downloading') && await page.locator('#u-available progress').count() === 1, 'download progress shown');
  // native pushes: error, then disabled build
  await page.evaluate(() => window.__bridgeReceive({ event: 'state', data: { ...window.__state, update: { current: '1.1.0', status: 'available', latest: '1.2.0', notes: '', error: 'The update failed: no connection' } } }));
  ok((await page.textContent('#u-available')).includes('no connection'), 'update errors shown');
  await page.evaluate(() => window.__bridgeReceive({ event: 'state', data: { ...window.__state, update: { current: '1.1.0', status: 'disabled' } } }));
  ok((await page.textContent('#u-status')).includes('set up') && await page.locator('#u-check').isDisabled(), 'disabled build explains itself');
  await page.click('#tab-wallpapers');
  await page.evaluate(() => window.__bridgeReceive({ event: 'focus', data: 'update' }));
  ok(await page.isVisible('#updates'), 'focus event from the menu opens the Updates section');

  ok(errors.length === 0, 'no page errors' + (errors.length ? ': ' + errors.join(' | ') : ''));
  await ctx.close();
}
await browser.close();
console.log(failures ? `\n${failures} FAILED` : '\nall passed');
process.exit(failures ? 1 : 0);
