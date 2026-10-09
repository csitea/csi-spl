// Spec 107 v1.2 T015 (owner R11): the hours panel's Team and Download tabs,
// driven the same way on the desktop panel (calendar.test.mjs, 1440) and the
// phone's hours sheet (calendar-phone.test.mjs, 390). The mock workspace
// (src/utils/hours-team-mock.mjs) answers GET /v1/hours, PUT
// /v1/hours/periods and the export as the hub's T008 / T009: three members,
// a period two weeks back is frozen for all of them.
//
// Expected totals of that period (Mon..Fri, the mock's entries):
//   HUM-1 5 x 5:30 = 27:30 (1650), HUM-2 5 x 3:45 + 0:15 x 15 = 22:30 (1350),
//   HUM-3 Mon / Wed / Fri 5:00 = 15:00 (900); all 65:00 (3900).

/** the mock role of a biz owner (spool.mock.me, act-as-mock.mjs) */
export const HOURS_BIZ_OWNER = { role: 'biz_owner', permissions: ['hours.read', 'hours.approve'] }
/** a member without hours.read: Mine only */
export const HOURS_MEMBER = { role: 'member', permissions: ['calendar.read'] }

/** a day of the period two weeks before the one holding `today` (always frozen in the mock) */
export function hoursFrozenDay(weekStart, addDays) {
  return addDays(weekStart, -12)
}

const rowsOf = (p, root) => p.$$eval(`${root} [data-test=hours-team-row]`, (els) => els.map((e) => `${e.getAttribute('data-member')}:${e.getAttribute('data-state')}:${e.getAttribute('data-total')}`))
const waitRow = (p, root, member, state) => p.waitForFunction((r, m, s) => document.querySelector(`${r} [data-test=hours-team-row][data-member="${m}"]`)?.getAttribute('data-state') === s, { timeout: 10000 }, root, member, state).then(() => true, () => false)

/**
 * @param {any} p a puppeteer page on /calendar?d=<hoursFrozenDay>, the panel open in `root`
 * @param {string} root the panel's selector
 * @param {string} w the run's label
 * @param {(name: string, pass: boolean, ev?: unknown) => void} ok
 * @param {{ layout: 'grid' | 'cards', shot?: (name: string) => Promise<void> }} o
 */
export async function driveHoursTeam(p, root, w, ok, o) {
  const tabs = await p.$$eval(`${root} [role=tab]`, (els) => els.map((e) => e.getAttribute('data-test'))).catch(() => [])
  ok(`T015 ${w}: hours.read shows the Mine, Team and Download tabs`, tabs.join() === 'hours-panel-tab-mine,hours-panel-tab-team,hours-panel-tab-download', tabs)
  await p.click(`${root} [data-test=hours-panel-tab-team]`).catch(() => {})
  const ready = await p.waitForSelector(`${root} [data-test=hours-team][data-state=ready]`, { visible: true, timeout: 10000 }).catch(() => null)
  ok(`T015 ${w}: the Team tab loads GET /v1/hours`, Boolean(ready))
  const layout = await p.$eval(`${root} [data-test=hours-team]`, (el) => el.getAttribute('data-layout')).catch(() => '')
  ok(`T015 ${w}: the Team view is a ${o.layout === 'grid' ? 'members x days grid' : 'card per member'}`, layout === o.layout, layout)
  const rows = await rowsOf(p, root)
  ok(`T015 ${w}: each member with the period state and approved total`, rows.join() === 'HUM-1:frozen:1650,HUM-2:frozen:1350,HUM-3:frozen:900', rows)
  if (o.layout === 'grid') {
    const g = await p.evaluate((r) => ({
      total: document.querySelector(`${r} [data-test=hours-team-totals]`)?.getAttribute('data-total') || '',
      cells: [...document.querySelectorAll(`${r} [data-test=hours-team-row][data-member="HUM-1"] [data-test=hours-team-cell]`)].map((c) => c.textContent.trim()),
      heads: document.querySelectorAll(`${r} .hours-team__daycol`).length,
    }), root)
    ok(`T015 ${w}: approved minutes per cell, totals per column`, g.total === '3900' && g.cells.slice(0, 5).every((c) => c === '5:30') && g.heads === 5, g)
  }
  await p.click(`${root} [data-test=hours-team-row][data-member="HUM-1"] [data-test=hours-team-name]`)
  const parts = await p.waitForFunction((r) => document.querySelectorAll(`${r} [data-test=hours-team-breakdown] li`).length, { timeout: 5000 }, root).then((h) => h.jsonValue(), () => 0)
  ok(`T015 ${w}: a tap on a member shows the per-target breakdown`, parts === 3, parts)
  await p.select(`${root} [data-test=hours-team-filter-kind]`, 'cal')
  const cal = await rowsOf(p, root)
  ok(`T015 ${w}: the kind filter keeps meetings only`, cal.join() === 'HUM-1:frozen:300,HUM-2:frozen:0,HUM-3:frozen:0', cal)
  await p.select(`${root} [data-test=hours-team-filter-kind]`, '')
  await p.select(`${root} [data-test=hours-team-filter-member]`, 'HUM-2')
  const one = await rowsOf(p, root)
  ok(`T015 ${w}: the member filter keeps one member`, one.join() === 'HUM-2:frozen:1350', one)
  await p.select(`${root} [data-test=hours-team-filter-member]`, '')

  await p.click(`${root} [data-test=hours-team-approve][data-member="HUM-1"]`)
  ok(`T015 ${w}: Approve makes one member's period final`, await waitRow(p, root, 'HUM-1', 'approved'), await rowsOf(p, root))
  await p.click(`${root} [data-test=hours-team-return][data-member="HUM-2"]`)
  const form = await p.waitForSelector(`${root} [data-test=hours-team-return-form][data-member="HUM-2"]`, { visible: true, timeout: 5000 }).catch(() => null)
  const blocked = form ? await p.$eval(`${root} [data-test=hours-team-return-send]`, (b) => b.disabled) : false
  ok(`T015 ${w}: Return asks for a note first`, Boolean(form) && blocked)
  await p.type(`${root} [data-test=hours-team-note]`, 'Tuesday counted twice')
  await p.click(`${root} [data-test=hours-team-return-send]`)
  ok(`T015 ${w}: Return with a note reopens that member only`, await waitRow(p, root, 'HUM-2', 'returned') && (await rowsOf(p, root)).join() === 'HUM-1:approved:1650,HUM-2:returned:1350,HUM-3:frozen:900', await rowsOf(p, root))
  const shownNote = await p.$eval(`${root} [data-test=hours-team]`, (el) => el.textContent.includes('Tuesday counted twice')).catch(() => false)
  ok(`T015 ${w}: the returned member shows the note`, shownNote)
  await p.click(`${root} [data-test=hours-team-approve-all]`)
  ok(`T015 ${w}: Approve all moves the frozen rest, the returned member stays`, await waitRow(p, root, 'HUM-3', 'approved') && (await rowsOf(p, root)).join() === 'HUM-1:approved:1650,HUM-2:returned:1350,HUM-3:approved:900', await rowsOf(p, root))
  const allOff = await p.$eval(`${root} [data-test=hours-team-approve-all]`, (b) => b.disabled).catch(() => false)
  ok(`T015 ${w}: nothing frozen left: Approve all is off`, allOff)
  const short = await p.$$eval(`${root} [data-test=hours-team] button:not([disabled]), ${root} [data-test=hours-team] select`, (els) => els.filter((e) => e.getBoundingClientRect().height < 44).length)
  ok(`T015 ${w}: the Team controls are >= 44 px tall`, short === 0, short)
  if (o.shot) await o.shot('team')

  await p.click(`${root} [data-test=hours-panel-tab-download]`)
  const dl = await p.waitForSelector(`${root} [data-test=hours-download]`, { visible: true, timeout: 10000 }).catch(() => null)
  const final = dl ? await p.$eval(`${root} [data-test=hours-dl-final]`, (c) => c.checked) : false
  ok(`T015 ${w}: the Download tab, Final only by default`, Boolean(dl) && final)
  await p.click(`${root} [data-test=hours-dl-go]`)
  const csv = await p.waitForSelector(`${root} [data-test=hours-dl-done]`, { timeout: 10000 }).then((h) => h.evaluate((e) => ({ name: e.getAttribute('data-name'), type: e.getAttribute('data-type'), lines: Number(e.getAttribute('data-lines')) })), () => null)
  ok(`T015 ${w}: CSV of the final lines only (header + 15 + 3)`, Boolean(csv && /^hours-.+\.csv$/.test(csv.name) && csv.type.startsWith('text/csv') && csv.lines === 19), csv)
  await p.click(`${root} [data-test=hours-dl-format-xlsx]`)
  await p.click(`${root} [data-test=hours-dl-go]`)
  const xlsx = await p.waitForFunction((r) => {
    const e = document.querySelector(`${r} [data-test=hours-dl-done]`)
    return e && /\.xlsx$/.test(e.getAttribute('data-name') || '') ? { name: e.getAttribute('data-name'), type: e.getAttribute('data-type') } : null
  }, { timeout: 10000 }, root).then((h) => h.jsonValue(), () => null)
  ok(`T015 ${w}: XLSX with the spreadsheet type`, Boolean(xlsx && xlsx.type.includes('spreadsheetml')), xlsx)
  if (o.shot) await o.shot('download')
}
