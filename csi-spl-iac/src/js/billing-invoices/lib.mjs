// lib.mjs - the pure parts of the billing-invoice download (spec 123 section
// 15, SPL-5220): which rows of the console's billing documents list to save,
// and under which file name. No browser, no network: download.mjs drives
// Chrome, this file only decides, so node --test covers it without a login.

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

// windowStart('2026-11-10', 12) -> '2025-11-10': the first day of the window
// "the last <months> months from the day of the call".
export function windowStart(today, months) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(today);
  if (!m) throw new Error(`the day must be YYYY-MM-DD, got: ${today}`);
  const idx = Number(m[1]) * 12 + Number(m[2]) - 1 - months;
  const y = Math.floor(idx / 12);
  const mo = (idx % 12) + 1;
  const last = new Date(Date.UTC(y, mo, 0)).getUTCDate();
  const d = Math.min(Number(m[3]), last);
  return `${String(y).padStart(4, '0')}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

const iso = (y, mo, d) => {
  const t = new Date(Date.UTC(y, mo - 1, d));
  if (t.getUTCFullYear() !== y || t.getUTCMonth() !== mo - 1 || t.getUTCDate() !== d) return null;
  return t.toISOString().slice(0, 10);
};

// parseDocDate(text) -> 'YYYY-MM-DD' | null. The first date in a row, in the
// forms the console shows: 2026-10-31, Oct 31, 2026, 31 Oct 2026, 31.10.2026.
export function parseDocDate(text) {
  let m = /\b(\d{4})-(\d{2})-(\d{2})\b/.exec(text);
  if (m) return iso(Number(m[1]), Number(m[2]), Number(m[3]));
  m = /\b([A-Za-z]{3})[a-z]*\.? (\d{1,2}),? (\d{4})\b/.exec(text);
  if (m && MONTHS.includes(m[1].toLowerCase())) return iso(Number(m[3]), MONTHS.indexOf(m[1].toLowerCase()) + 1, Number(m[2]));
  m = /\b(\d{1,2})\.? ([A-Za-z]{3})[a-z]*\.? (\d{4})\b/.exec(text);
  if (m && MONTHS.includes(m[2].toLowerCase())) return iso(Number(m[3]), MONTHS.indexOf(m[2].toLowerCase()) + 1, Number(m[1]));
  m = /\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b/.exec(text);
  if (m) return iso(Number(m[3]), Number(m[2]), Number(m[1]));
  return null;
}

// selectRows(texts, today, months) -> [{index, date, file}]: the rows that
// name an invoice (not a payment or a receipt) dated inside the window, each
// with its file name <date>-<document number, or row-<index>>.pdf.
export function selectRows(texts, today, months) {
  const from = windowStart(today, months);
  const out = [];
  texts.forEach((text, index) => {
    if (!/invoice/i.test(text) || /\b(payment|receipt)\b/i.test(text)) return;
    const date = parseDocDate(text);
    if (!date || date < from || date > today) return;
    const num = /\b(\d{8,})\b/.exec(text);
    out.push({ index, date, file: `${date}-${num ? num[1] : `row-${index}`}.pdf` });
  });
  return out;
}

// maskId('0A1B2C-3D4E5F-6A7B8C') -> 'XXXXXX-XXXXXX-XX7B8C': an account id in a
// log line, the last 4 kept (SPL-5810).
export const maskId = (id) => `XXXXXX-XXXXXX-XX${String(id).slice(-4)}`;

// failLine(id, what) -> the one line a failed account prints (SPL-5810).
export const failLine = (id, what) => `FATAL ${maskId(id)}: ${what}`;

const ENT = { amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'", nbsp: ' ' };
const decode = (s) => s.replace(/&(amp|lt|gt|quot|#39|nbsp);/g, (_, k) => ENT[k]);

// htmlText(html) -> the visible text of a page or a fragment, one space apart.
export function htmlText(html) {
  return decode(String(html).replace(/<(script|style)\b[\s\S]*?<\/\1>/gi, ' ').replace(/<[^>]*>/g, ' '))
    .replace(/\s+/g, ' ').trim();
}

// isNotFound(html): the console's "URL not found" page (owner msg 917d252a),
// or another not-found page shown in place of the one asked for.
export function isNotFound(html) {
  return /\b(URL|page) (was )?not found\b|\brequested URL was not found\b/i.test(htmlText(html));
}

// navEntries(html) -> [{label, href}]: every link of the page, labelled by its
// aria-label, else by its text.
export function navEntries(html) {
  const out = [];
  for (const m of String(html).matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/gi)) {
    const attr = (k) => (new RegExp(`\\s${k}\\s*=\\s*"([^"]*)"`, 'i').exec(m[1]) || [])[1];
    const label = htmlText(attr('aria-label') || m[2]);
    if (label) out.push({ label, href: attr('href') ? decode(attr('href')) : null });
  }
  return out;
}

// pickInvoicesEntry(entries) -> the Billing navigation entry that leads to the
// documents: "Invoices" (a self-serve account), else "Payment status" (an
// invoiced account), as Google's get-invoice how-to names them; null if neither.
export function pickInvoicesEntry(entries) {
  for (const re of [/^invoices$/i, /^payment status$/i]) {
    const e = entries.find((x) => re.test(x.label));
    if (e) return e;
  }
  return null;
}
