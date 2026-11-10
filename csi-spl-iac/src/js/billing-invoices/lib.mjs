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
