// Spec 071 7.4.1 (SPL-6239 row T9; owner HUM-10, t1 78f0138c, msg f87c349b):
// Monitoring > Boxes opens with one table, one row per box, one column per
// key attribute. This builds the rows from what the page already reads: the
// roster's box rows (box-rows.mjs, in the page's order) and today's
// GET /v1/tenant/box-stats samples. Every number is the box's NEWEST sample
// (latestBoxStat), the same row its card below shows, so the table and the
// details never disagree; a box with no sample has `sample: null`, never 0.
import { boxDisksOf, currentOf, diskUsedPct, latestBoxStat, lowestDisk, memUsedPct } from './box-resources.mjs'

/**
 * @typedef {{ at: string, ramPct: number, ramFreeKB: number,
 *   disk: { mount: string, pct: number } | null, load1: number, cpus: number,
 *   agentsLive: number }} BoxSummarySample
 * @typedef {{ id: string, tag: string, online: boolean, sample: BoxSummarySample | null }} BoxSummaryRow
 */

/**
 * One summary row per box, in the order given.
 * @param {{ id: string, tag: string, online: boolean }[]} boxes the page's rows, online first
 * @param {import('./box-resources.mjs').BoxStat[]} stats the box-stats rows
 * @returns {BoxSummaryRow[]}
 */
export function boxSummaryRows(boxes, stats) {
  return (Array.isArray(boxes) ? boxes : []).map((b) => ({
    id: b.id,
    tag: b.tag,
    online: Boolean(b.online),
    sample: summarySampleOf(latestBoxStat(stats, b.id)),
  }))
}

/**
 * The table's readings of one sample, or null with none.
 * @param {import('./box-resources.mjs').BoxStat | null} row
 * @returns {BoxSummarySample | null}
 */
export function summarySampleOf(row) {
  const cur = currentOf(row)
  if (!row || !cur) return null
  const d = lowestDisk(boxDisksOf(row))
  return {
    at: cur.at,
    ramPct: memUsedPct(cur),
    ramFreeKB: cur.memAvailKB,
    disk: d ? { mount: d.mount, pct: diskUsedPct(d) } : null,
    load1: cur.load1,
    cpus: cur.cpus,
    agentsLive: cur.agentsLive,
  }
}
