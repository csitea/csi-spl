// download.mjs - save every billing account's invoice PDFs of the last
// <months> months from the console (spec 123 section 15, SPL-5220). Run ONLY
// through do_gcp_billing_invoices_browser, by the owner at his own desk: it
// opens a visible Chrome on a THROWAWAY profile and the owner logs in there
// himself, each run. chromium.launch() + newContext() (never a persistent
// context): playwright makes the profile under TMPDIR, a mktemp dir the
// action removes when the run ends, so no session survives it. Nothing here
// reads, prints or stores a password or a cookie.
// FRAGILE by design (the owner's choice B): it reads the console's billing
// documents page, which Google may change at any time. When any account's page
// shows no invoice row in the window, it says so and exits 2; nothing is
// guessed.
import { createRequire } from 'node:module';
import { existsSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { selectRows } from './lib.mjs';

const env = (k) => {
  const v = process.env[k];
  if (!v) { console.error(`FATAL ${k} is unset (run do_gcp_billing_invoices_browser)`); process.exit(1); }
  return v;
};
const accounts = env('BILLING_ACCOUNTS').split(',').filter(Boolean);
const today = env('BILLING_TODAY');
const months = Number(env('BILLING_MONTHS'));
const pdfRoot = env('BILLING_PDF_DIR');
const dry = process.env.BILLING_DRY === '1';
const LOGIN_WAIT_MS = 10 * 60 * 1000;
const mask = (id) => `XXXXXX-XXXXXX-${id.slice(-6)}`;

const require = createRequire(path.join(env('BILLING_PW_DIR'), 'package.json'));
const { chromium } = require('playwright-core');

async function waitLoggedIn(page) {
  const until = Date.now() + LOGIN_WAIT_MS;
  let told = false;
  while (!new URL(page.url()).hostname.startsWith('console.cloud.google.com')) {
    if (!told) { console.log('INFO log in in the Chrome window (this script never sees your password); waiting up to 10 min'); told = true; }
    if (Date.now() > until) throw new Error('no login within 10 min');
    await page.waitForTimeout(2000);
  }
}

async function documentsFrame(page) {
  const until = Date.now() + 90000;
  while (Date.now() < until) {
    const f = page.frames().find((fr) => /payments\.google\.com/.test(fr.url()));
    if (f && (await f.locator('[role="row"], tr').count()) > 1) return f;
    await page.waitForTimeout(2000);
  }
  return null;
}

async function clickDownload(page, frame, row) {
  const direct = row.locator('[aria-label*="ownload" i], [data-tooltip*="ownload" i], a[href*="download" i]').first();
  if (await direct.count()) return Promise.all([page.waitForEvent('download', { timeout: 60000 }), direct.click()]);
  await row.locator('[aria-label*="more" i], [aria-label*="menu" i], [aria-haspopup]').first().click();
  const item = frame.getByRole('menuitem', { name: /download/i }).first();
  return Promise.all([page.waitForEvent('download', { timeout: 60000 }), item.click()]);
}

async function oneAccount(page, id) {
  await page.goto(`https://console.cloud.google.com/billing/${id}/documents`);
  await waitLoggedIn(page);
  const frame = await documentsFrame(page);
  if (!frame) { console.log(`WARNING ${mask(id)}: no documents list found (the page changed?)`); return 0; }
  const rows = frame.locator('[role="row"], tr');
  const picks = selectRows(await rows.allInnerTexts(), today, months);
  if (!picks.length) { console.log(`WARNING ${mask(id)}: no invoice row in the window (the page changed?)`); return 0; }
  const dir = path.join(pdfRoot, id);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (const p of picks) {
    const file = path.join(dir, p.file);
    if (existsSync(file)) { console.log(`OK ${mask(id)} ${p.file} already there`); continue; }
    if (dry) { console.log(`INFO DRY ${mask(id)} would save ${p.file}`); continue; }
    const [dl] = await clickDownload(page, frame, rows.nth(p.index));
    await dl.saveAs(file);
    console.log(`OK ${mask(id)} saved ${p.file}`);
  }
  return picks.length;
}

const browser = await chromium.launch({ executablePath: env('BILLING_CHROME'), headless: false });
let missing = 0;
try {
  const ctx = await browser.newContext({ acceptDownloads: true });
  const page = await ctx.newPage();
  for (const id of accounts) if (!(await oneAccount(page, id))) missing += 1;
} finally {
  await browser.close();
}
if (missing) console.log(`WARNING ${missing} of ${accounts.length} account(s) showed no invoice row: exit 2`);
process.exit(missing ? 2 : 0);
