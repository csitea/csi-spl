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
import { existsSync, mkdirSync, openSync, readSync, closeSync, rmSync } from 'node:fs';
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
const POLL_MS = Math.min(Number(process.env.BILLING_POLL_MS || 2000), PAGE_WAIT_MS);
const CONSOLE = 'https://console.cloud.google.com';
const ROWS = '[role="row"], tr';
const STABLE_READS = 3;

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

// poll(page, probe) - probe() until it returns a value, POLL_MS apart, for at
// most PAGE_WAIT_MS of waiting. The budget counts the waits, not the wall
// clock, so a slow probe (a loaded box) never cuts the number of reads short:
// a wall-clock deadline let 3 slow probes outrun it and failed a list that was
// there (SPL-6333). A probe's own time comes on top of the budget.
async function poll(page, probe) {
  for (let waited = 0; ; waited += POLL_MS) {
    const v = await probe();
    if (v) return v;
    if (waited >= PAGE_WAIT_MS) return null;
    await page.waitForTimeout(POLL_MS);
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
// iframe when there is one, else the page itself. The list may fill in
// lazily, so it is taken only when no progress bar shows and its row count
// read the same STABLE_READS polls in a row (R7 c-073 W1).
async function documentsFrame(page, id, label) {
  let last = -1, same = 0;
  const got = await poll(page, async () => {
    if (isNotFound(await page.content())) return 'not-found';
    const frames = page.frames().sort((a, b) => /payments\.google\.com/.test(b.url()) - /payments\.google\.com/.test(a.url()));
    for (const f of frames) {
      const n = await f.locator(ROWS).count();
      if (n <= 1) continue;
      if (await f.locator('[role="progressbar"]').count()) { last = -1; same = 0; return null; }
      same = n === last ? same + 1 : 1;
      last = n;
      return same >= STABLE_READS ? f : null;
    }
    last = -1;
    return null;
  });
  if (got === 'not-found') fail(id, `the console shows "URL not found" behind the "${label}" entry`);
  if (!got) fail(id, `no documents list on the "${label}" page, or it never stopped loading (the console changed?)`);
  if (await got.locator('[aria-label*="next page" i]:not([disabled]):not([aria-disabled="true"])').count()) {
    fail(id, `the documents list on the "${label}" page has more pages; this run reads one page only`);
  }
  return got;
}

// isPdf(file) - the saved file starts with the PDF magic number.
function isPdf(file) {
  const fd = openSync(file, 'r');
  const b = Buffer.alloc(5);
  try { readSync(fd, b, 0, 5, 0); } finally { closeSync(fd); }
  return b.toString('latin1') === '%PDF-';
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
  const to = entry.href ? new URL(entry.href, page.url()) : null;
  if (to && to.hostname !== new URL(CONSOLE).hostname) fail(id, `the "${entry.label}" entry leads off the console (${to.hostname})`);
  if (to) await page.goto(to.href);
  else await page.getByRole('link', { name: entry.label, exact: true }).first().click();
  const frame = await documentsFrame(page, id, entry.label);
  const rows = frame.locator(ROWS);
  const texts = await rows.allInnerTexts();
  const picks = selectRows(texts, today, months);
  if (!picks.length) fail(id, `no invoice row dated in the last ${months} months on the "${entry.label}" page (the console changed?)`);
  const dir = path.join(pdfRoot, id);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (const p of picks) {
    const file = path.join(dir, p.file);
    if (existsSync(file)) { console.log(`OK ${maskId(id)} ${p.file} already there`); continue; }
    if (dry) { console.log(`INFO DRY ${maskId(id)} would save ${p.file} (${entry.label})`); continue; }
    const dl = await clickDownload(page, frame, rows.nth(p.index));
    if (!/\.pdf$/i.test(dl.suggestedFilename())) fail(id, `one row gave no PDF (a .${dl.suggestedFilename().split('.').pop()} file) for ${p.file}`);
    await dl.saveAs(file);
    if (!isPdf(file)) { rmSync(file, { force: true }); fail(id, `the file saved for ${p.file} is no PDF (removed)`); }
    console.log(`OK ${maskId(id)} saved ${p.file}`);
  }
  await recheckRows(page, rows, texts.length, id, entry.label);
}

// recheckRows - after the saves, read the row count STABLE_READS more times
// (a poll apart): a list that grew or shrank since it was read was read
// half full, so the account fails (R7 c-073 N6). A list that pauses longer
// than both windows together with no progress bar is still not seen.
async function recheckRows(page, rows, n, id, label) {
  for (let i = 0; i < STABLE_READS; i += 1) {
    await page.waitForTimeout(POLL_MS);
    const now = await rows.count();
    if (now !== n) fail(id, `the documents list on the "${label}" page changed from ${n} to ${now} rows after it was read (it was still loading); run again`);
  }
}

let browser;
try {
  browser = await chromium.launch({ executablePath: env('BILLING_CHROME'), headless: false });
} catch (e) {
  const why = String(e.message).split('\n')[0].replace(/--user-data-dir=\S+/g, '--user-data-dir=<throwaway>').slice(0, 200);
  console.log(`FATAL cannot start Chrome (BILLING_CHROME): ${why}`);
  process.exit(2);
}
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
