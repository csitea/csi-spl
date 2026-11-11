// SPL-2466 row 04 (md-tables panel plan v1.0, section 3.2): the sort helper
// for a table in a post reads numbers with units, dates and clock times,
// collates text, keeps empty cells last in both directions and keeps the
// author's order on ties.
//
// Red control: sortOrder as a plain localeCompare sort (no kinds, no empty
// rule) fails 6 checks: value, units, descending, empty cells, collation and
// descending ties (measured on 7acf41189, n=1).
//
// Run: node tests/unit/table-sort.test.mjs
import { importTs } from './lib/load-ts.mjs'

const { cellText, columnKind, isEmptyCell, parseCell, sortOrder } = await importTs('src/utils/table-sort.ts')

let failed = 0
const ok = (name, cond, why = '') => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${why}`) }
}
const eq = (name, got, want) => ok(name, JSON.stringify(got) === JSON.stringify(want), `got ${JSON.stringify(got)} want ${JSON.stringify(want)}`)
const sorted = (texts, dir = 'ascending', locale = 'en') => sortOrder(texts, dir, locale).map((i) => texts[i])

// ---- parseCell --------------------------------------------------------------
eq('a negative number with a unit', parseCell('-28 dBFS'), { kind: 'num', v: -28 })
eq('a unicode minus', parseCell('−3.5'), { kind: 'num', v: -3.5 })
eq('a percentage', parseCell('74%'), { kind: 'num', v: 74 })
eq('thousands separators', parseCell('1,234,567'), { kind: 'num', v: 1234567 })
eq('a currency prefix', parseCell('€12.50'), { kind: 'num', v: 12.5 })
eq('a currency suffix', parseCell('40 EUR'), { kind: 'num', v: 40 })
eq('a size scales to bytes', parseCell('1.2 MB'), { kind: 'num', v: 1.2e6 })
eq('a duration scales to seconds', parseCell('250 ms'), { kind: 'num', v: 0.25 })
eq('a leading decimal point', parseCell('.5'), { kind: 'num', v: 0.5 })
eq('an ISO date', parseCell('2026-11-11'), { kind: 'date', v: Date.UTC(2026, 10, 11) })
eq('an ISO date-time in UTC', parseCell('2026-11-11T08:59:30Z'), { kind: 'date', v: Date.UTC(2026, 10, 11, 8, 59, 30) })
eq('an ISO date-time with an offset', parseCell('2026-11-11 10:59+02:00'), { kind: 'date', v: Date.UTC(2026, 10, 11, 8, 59) })
eq('a short UTC time', parseCell('17:05Z'), { kind: 'clock', v: 17 * 3600 + 5 * 60 })
eq('a time with seconds', parseCell('09:00:30'), { kind: 'clock', v: 9 * 3600 + 30 })
for (const s of ['FR-ML-001', 'dbafa68e', '1.2.3', 'v2', '20 per path', 'abc', '%', '25:00']) {
  eq(`"${s}" is text`, parseCell(s), null)
}

// ---- empty cells and cell text -------------------------------------------------
for (const s of ['', ' ', '-', '—', '–', 'N/A', 'n/a']) ok(`"${s}" is an empty cell`, isEmptyCell(s))
ok('"0" is not an empty cell', !isEmptyCell('0'))
eq('cell text joins inline children', cellText({ tag: 'td', attrs: {}, children: ['a ', { tag: 'code', attrs: {}, children: ['b'] }, '  c'] }), 'a b c')

// ---- column kind -------------------------------------------------------------
eq('a column of numbers is num', columnKind(['3', '-1', '10 KB']), 'num')
eq('4 of 5 numbers (80%) is still num', columnKind(['1', '2', '3', '4', 'many']), 'num')
eq('3 of 5 numbers is text', columnKind(['1', '2', '3', 'x', 'y']), 'text')
eq('empty cells do not count against the kind', columnKind(['1', '-', '2', '', '3']), 'num')
eq('dates', columnKind(['2026-11-01', '2026-10-31']), 'date')
eq('an all-empty column is text', columnKind(['-', '']), 'text')

// ---- sortOrder -----------------------------------------------------------------
eq('negative numbers sort below positive ones', sorted(['5', '-28', '0', '-3']), ['-28', '-3', '0', '5'])
eq('numbers sort by value, not as text', sorted(['10', '9', '100', '1.5']), ['1.5', '9', '10', '100'])
eq('units scale before they compare', sorted(['900 KB', '1.2 MB', '149.4 KB']), ['149.4 KB', '900 KB', '1.2 MB'])
eq('descending reverses the values', sorted(['2', '30', '4'], 'descending'), ['30', '4', '2'])
eq('empty cells last ascending', sorted(['3', '-', '1', '', '2']), ['1', '2', '3', '-', ''])
eq('empty cells last descending, in the author\'s order', sorted(['3', '-', '1', '', '2'], 'descending'), ['3', '2', '1', '-', ''])
eq('a stray text cell in a number column sits after the numbers, before the empties', sorted(['2', 'n/a', 'many', '1', '3', '4']), ['1', '2', '3', '4', 'many', 'n/a'])
eq('dates sort in time order', sorted(['2026-11-11', '2025-01-02', '2026-01-31T10:00Z']), ['2025-01-02', '2026-01-31T10:00Z', '2026-11-11'])
eq('clock times sort in time order', sorted(['17:05Z', '09:30Z', '23:59Z']), ['09:30Z', '17:05Z', '23:59Z'])
eq('text collates case-insensitively with numeric runs', sorted(['item 10', 'Item 2', 'beta', 'Alpha']), ['Alpha', 'beta', 'Item 2', 'item 10'])
eq('ties keep the author\'s order (stable)', sortOrder(['b', 'a', 'B', 'A'], 'ascending', 'en'), [1, 3, 0, 2])
eq('ties keep the author\'s order descending too', sortOrder(['1', '2', '1', '2'], 'descending', 'en'), [1, 3, 0, 2])
eq('an unknown locale falls back to the default collator', sorted(['b', 'a'], 'ascending', 'xx-invalid-@@'), ['a', 'b'])

console.log(failed ? `\ntable-sort: ${failed} FAILED` : '\ntable-sort: all OK')
process.exit(failed ? 1 : 0)
