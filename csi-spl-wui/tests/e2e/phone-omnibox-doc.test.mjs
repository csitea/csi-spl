// Test: omnibox visibility on phone widths during workspace doc editing.
// Extends docs-ws-edit.test.mjs to verify:
// - Omnibox visible on phone when NOT editing.
// - Omnibox hidden on phone when editing.
// - Control: omnibox remains visible on desktop.

import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { startServer } from './lib/server.mjs';
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs';

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000);
const results = [];
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass });
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`);
};

async function launch() {
  const require = createRequire(import.meta.url);
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href;
      const mod = await import(href);
      const puppeteer = mod.default ?? mod;
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      });
    } catch { /* try next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE');
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const WELCOME = 'welcome.md';

// Check if the omnibox is visible
const omniboxVisible = async (p) => {
  return p.evaluate(() => {
    const omnibox = document.querySelector('[data-test=top-bar-omnibox]');
    if (!omnibox) return false;
    const style = window.getComputedStyle(omnibox);
    return style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0';
  });
};

const server = await startServer();
const browser = await launch();
try {
  console.log('-- 390x740 phone (omnibox visibility)');
  const m = await browser.newPage();
  await m.setViewport({ width: 390, height: 740, isMobile: true, hasTouch: true });
  await m.goto(server.base + '/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT });
  await m.waitForSelector('[data-test=ws-docs][data-state=ready]', { visible: true, timeout: 15000 });
  
  // Open the doc
  await m.click(`[data-test=ws-docs-file][data-path="${WELCOME}"]`);
  await m.waitForSelector('[data-test=ws-doc]', { visible: true, timeout: 15000 });
  
  // Verify omnibox is visible when NOT editing
  let visible = await omniboxVisible(m);
  ok('phone: omnibox visible when NOT editing', visible);
  
  // Focus the title (edit mode)
  await m.click('[data-test=ws-doc-doctitle]');
  await sleep(500); // Wait for focus to settle
  visible = await omniboxVisible(m);
  ok('phone: omnibox hidden when editing', !visible);
  
  // Blur (exit edit mode)
  await m.click('[data-test=ws-doc-search]');
  await sleep(500);
  visible = await omniboxVisible(m);
  ok('phone: omnibox visible after editing', visible);
  
  // Control: desktop (omnibox always visible)
  console.log('-- 1440x900 desktop (control)');
  const d = await browser.newPage();
  await d.setViewport({ width: 1440, height: 900 });
  await d.goto(server.base + '/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT });
  await d.waitForSelector('[data-test=ws-docs][data-state=ready]', { visible: true, timeout: 15000 });
  await d.click(`[data-test=ws-docs-file][data-path="${WELCOME}"]`);
  await d.waitForSelector('[data-test=ws-doc]', { visible: true, timeout: 15000 });
  
  // Verify omnibox is visible when NOT editing
  visible = await omniboxVisible(d);
  ok('desktop: omnibox visible when NOT editing', visible);
  
  // Focus the title (edit mode)
  await d.click('[data-test=ws-doc-doctitle]');
  await sleep(500);
  visible = await omniboxVisible(d);
  ok('desktop: omnibox visible when editing (control)', visible);
  
  await d.close();
  await m.close();
} finally {
  await browser.close();
  await server.stop();
}

const failed = results.filter((r) => !r.ok).length;
console.log(failed ? `phone-omnibox-doc: ${failed} FAILED` : `phone-omnibox-doc: all ${results.length} passed`);
process.exit(failed ? 1 : 0);