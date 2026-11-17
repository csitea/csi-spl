// download.mjs - save every billing account's invoice PDFs of the last
// <months> months from the console (spec 123 section 15, SPL-5220). Run ONLY
// through do_gcp_billing_invoices_browser, by the owner at his own desk: it
// opens a visible Chrome on a THROWAWAY profile and the owner logs in there
// himself, each run. chromium.launch() + newContext() (never a persistent
// context): playwright makes the profile under TMPDIR, a mktemp dir the
// action removes when the run ends, so no session survives it. Nothing here
// reads, prints or stores a password or a cookie.
// FRAGILE by design (the owner's choice B): it reads the console's pages,
// which Google may change at any time. It opens the billing account's
// overview and follows the console's own Billing navigation to "Invoices"
// (else "Payment status", an invoiced account), never a hard-coded deep path:
// /billing/<id>/documents went "URL not found" (SPL-5810). A not-found page,
// no such entry, no documents list or no invoice row in the window fails that
// account with one FATAL line (the id masked to its last 4); the run then
// exits 2. Nothing is guessed.
import { createRequire } from 'node:module';
import { existsSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { selectRows, maskId, failLine, isNotFound, navEntries, pickInvoicesEntry } from './lib.mjs';

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
const PAGE_WAIT_MS = Number(process.env.BILLING_PAGE_WAIT_MS || 90000);
const CONSOLE = 'https://console.cloud.google.com';
const ROWS = '[role="row"], tr';

const require = createRequire(path.join(env('BILLING_PW_DIR'), 'package.json'));
const { chromium } = require('playwright-core');

// AccountFail - this account is done for; its message is the one FATAL line.
class AccountFail extends Error {}
const fail = (id, what) => { throw new AccountFail(failLine(id, what)); };

async function waitLoggedIn(page) {
  const until = Date.now() + LOGIN_WAIT_MS;
  let told = false;
  while (!new URL(page.url()).hostname.startsWith('console.cloud.google.com')) {
    if (!told) { console.log('INFO log in in the Chrome window (this script never sees your password); waiting up to 10 min'); told = true; }
    if (Date.now() > until) throw new Error('no login within 10 min');
    await page.waitForTimeout(2000);
  }
}

// poll(page, probe) - probe() until it returns a value, at most PAGE_WAIT_MS.
async function poll(page, probe) {
  const until = Date.now() + PAGE_WAIT_MS;
  for (;;) {
    const v = await probe();
    if (v) return v;
    if (Date.now() > until) return null;
    await page.waitForTimeout(Math.min(2000, PAGE_WAIT_MS));
  }
}

// invoicesEntry - the overview's Billing navigation entry to the documents.
async function invoicesEntry(page, id) {
  const got = await poll(page, async () => {
    const html = await page.content();
    if (isNotFound(html)) return 'not-found';
    return pickInvoicesEntry(navEntries(html));
  });
  if (got === 'not-found') fail(id, 'the console shows "URL not found" for the billing account overview (/billing/<account>)');
  if (!got) fail(id, 'no "Invoices" or "Payment status" entry in the Billing navigation of the account overview (the console changed?)');
  return got;
}

// documentsFrame - the frame that holds the documents list: the payments
// iframe when there is one, else the page itself.
async function documentsFrame(page, id, label) {
  const got = await poll(page, async () => {
    if (isNotFound(await page.content())) return 'not-found';
    const frames = page.frames().sort((a, b) => /payments\.google\.com/.test(b.url()) - /payments\.google\.com/.test(a.url()));
    for (const f of frames) if ((await f.locator(ROWS).count()) > 1) return f;
    return null;
  });
  if (got === 'not-found') fail(id, `the console shows "URL not found" behind the "${label}" entry`);
  if (!got) fail(id, `no documents list on the "${label}" page (the console changed?)`);
  return got;
}

async function clickDownload(page, frame, row) {
  const wait = () => page.waitForEvent('download', { timeout: 60000 });
  const direct = row.locator('[aria-label*="ownload" i], [data-tooltip*="ownload" i], a[href*="download" i]').first();
  if (await direct.count()) return (await Promise.all([wait(), direct.click()]))[0];
  const box = row.locator('[role="checkbox"], input[type="checkbox"]').first();
  if (await box.count()) {
    await box.click();
    const [dl] = await Promise.all([wait(), frame.getByRole('button', { name: /download selected/i }).first().click()]);
    await box.click();
    return dl;
  }
  await row.locator('[aria-label*="more" i], [aria-label*="menu" i], [aria-haspopup]').first().click();
  const item = frame.getByRole('menuitem', { name: /download/i }).first();
  return (await Promise.all([wait(), item.click()]))[0];
}

async function oneAccount(page, id) {
  await page.goto(`${CONSOLE}/billing/${id}`);
  await waitLoggedIn(page);
  const entry = await invoicesEntry(page, id);
  if (entry.href) await page.goto(new URL(entry.href, page.url()).href);
  else await page.getByRole('link', { name: entry.label, exact: true }).first().click();
  const frame = await documentsFrame(page, id, entry.label);
  const rows = frame.locator(ROWS);
  const picks = selectRows(await rows.allInnerTexts(), today, months);
  if (!picks.length) fail(id, `no invoice row dated in the last ${months} months on the "${entry.label}" page (the console changed?)`);
  const dir = path.join(pdfRoot, id);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (const p of picks) {
    const file = path.join(dir, p.file);
    if (existsSync(file)) { console.log(`OK ${maskId(id)} ${p.file} already there`); continue; }
    if (dry) { console.log(`INFO DRY ${maskId(id)} would save ${p.file} (${entry.label})`); continue; }
    const dl = await clickDownload(page, frame, rows.nth(p.index));
    if (/\.zip$/i.test(dl.suggestedFilename())) fail(id, `one row gave a zip, not a PDF (${p.file})`);
    await dl.saveAs(file);
    console.log(`OK ${maskId(id)} saved ${p.file}`);
  }
}

const browser = await chromium.launch({ executablePath: env('BILLING_CHROME'), headless: false });
let failed = 0;
try {
  const ctx = await browser.newContext({ acceptDownloads: true });
  const page = await ctx.newPage();
  for (const id of accounts) {
    try {
      await oneAccount(page, id);
    } catch (e) {
      failed += 1;
      const first = String(e.message).split('\n')[0].split(id).join(maskId(id));
      console.log(e instanceof AccountFail ? first : failLine(id, `the run broke: ${first}`));
      if (/no login/.test(first)) { failed = accounts.length; break; }
    }
  }
} finally {
  await browser.close();
}
if (failed) console.log(`FATAL ${failed} of ${accounts.length} account(s) failed (the FATAL lines above): exit 2`);
process.exit(failed ? 2 : 0);
