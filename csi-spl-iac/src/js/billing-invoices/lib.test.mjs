// node --test of lib.mjs (spec 123 section 15): the window, the date forms and
// the row choice, on synthetic rows. No browser, no login, no network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { windowStart, parseDocDate, selectRows } from './lib.mjs';

test('windowStart: 12 months back, the day clamped to the month', () => {
  assert.equal(windowStart('2026-11-10', 12), '2025-11-10');
  assert.equal(windowStart('2026-01-05', 1), '2025-12-05');
  assert.equal(windowStart('2026-03-31', 1), '2026-02-28');
  assert.throws(() => windowStart('10.11.2026', 12));
});

test('parseDocDate: the console forms, invalid dates refused', () => {
  assert.equal(parseDocDate('Invoice 2026-10-31 EUR'), '2026-10-31');
  assert.equal(parseDocDate('Oct 31, 2026 Invoice'), '2026-10-31');
  assert.equal(parseDocDate('31 Oct 2026 Invoice'), '2026-10-31');
  assert.equal(parseDocDate('31.10.2026 Invoice'), '2026-10-31');
  assert.equal(parseDocDate('Feb 30, 2026'), null);
  assert.equal(parseDocDate('no date here'), null);
});

test('selectRows: invoices in the window only, named by date and number', () => {
  const rows = [
    'Date Type Number Amount',
    'Nov 1, 2026 Invoice 5123456789 EUR 1,254.00',
    'Oct 1, 2026 Invoice EUR 980.00',
    'Oct 15, 2026 Payment 5123456790 EUR 980.00',
    'Oct 15, 2026 Payment receipt for invoice 5123456791',
    'Nov 1, 2025 Invoice 5100000001 EUR 10.00',
    'Dec 1, 2025 Invoice 5100000002 EUR 12.00',
    'Dec 1, 2026 Invoice 5100000003 EUR 1.00',
  ];
  assert.deepEqual(selectRows(rows, '2026-11-10', 12), [
    { index: 1, date: '2026-11-01', file: '2026-11-01-5123456789.pdf' },
    { index: 2, date: '2026-10-01', file: '2026-10-01-row-2.pdf' },
    { index: 6, date: '2025-12-01', file: '2025-12-01-5100000002.pdf' },
  ]);
});

test('selectRows CONTROL: a wider window takes the older invoice too', () => {
  const rows = ['Nov 1, 2025 Invoice 5100000001'];
  assert.equal(selectRows(rows, '2026-11-10', 12).length, 0);
  assert.equal(selectRows(rows, '2026-11-10', 13).length, 1);
});
