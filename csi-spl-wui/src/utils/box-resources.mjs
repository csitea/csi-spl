// HUM-10 (t1 f77c9f87): the Boxes page is three panes - the boxes list (the
// sidebar's Boxes section), the resources of the selected box (agents,
// hardware, OS, run-times) and, on the right, statistics for the resource
// selected in the middle. The selection rides the URL (`?r=<resource>`), so a
// link, a reload and the phone's Back all land on the same pane.
//
// The WUI reads only what the hub serves: the roster (agents, seats, the box's
// last hello, and the box facts c-220 serves on `boxes[]`: os, runtimes,
// system, network, facts_reported_at, agent_presence) and GET
// /v1/tenant/box-stats (load + memory history, per-hour avg / peak). The facts
// are a troubleshooting snapshot, collected at most once a day (owner
// 7e013eab), so their age shows beside them. What the hub does not serve shows
// as "not reported yet" - never made-up values.

/** The resources a box's middle pane lists, in order. */
export const BOX_RESOURCES = ['agents', 'hardware', 'system', 'os', 'runtimes', 'network']

/**
 * The selected resource from a route query value ('' = none selected).
 * @param {unknown} q route.query.r
 * @returns {string}
 */
export function boxResourceOf(q) {
  const v = String(Array.isArray(q) ? q[0] : q || '')
  return BOX_RESOURCES.includes(v) ? v : ''
}

/**
 * @typedef {{ box: string, at: string, load1: number, load5: number, load15: number,
 *   cpus: number, mem_total_kb: number, mem_avail_kb: number, swap_used_kb: number,
 *   agents_live: number, disks?: { mount: string, total_kb: number, avail_kb: number }[] }} BoxStat
 * @typedef {{ box: string, hour: string, n: number, cpus: number, load1_avg: number,
 *   load1_peak: number, mem_used_avg_kb: number, mem_used_peak_kb: number,
 *   mem_avail_min_kb: number, agents_avg: number, agents_peak: number,
 *   disks?: { mount: string, total_kb: number, avail_min_kb: number }[] }} BoxStatHour
 */

/**
 * The box-stats read as the pane needs it: rows (raw samples) and hours (one
 * per UTC hour, avg / peak), each [] when absent.
 * @param {{ rows?: unknown[], hours?: unknown[] } | null | undefined} body
 * @returns {{ rows: BoxStat[], hours: BoxStatHour[] }}
 */
export function boxStatsOf(body) {
  const rows = Array.isArray(body && body.rows) ? /** @type {BoxStat[]} */ (body.rows) : []
  const hours = Array.isArray(body && body.hours) ? /** @type {BoxStatHour[]} */ (body.hours) : []
  return { rows, hours }
}

/**
 * A reader without audit.read gets 403: the statistics are the operators'.
 * @param {unknown} err
 */
export function isBoxStatsForbidden(err) {
  return Number(err && /** @type {{ status?: number }} */ (err).status) === 403
}

/**
 * The disks of one sample (rdb 0118), sorted by mount; [] while the hub does
 * not serve them yet (c-202: read `disks ?? []`).
 * @param {BoxStat | null | undefined} row
 * @returns {{ mount: string, totalKB: number, availKB: number }[]}
 */
export function boxDisksOf(row) {
  const list = row && Array.isArray(row.disks) ? row.disks : []
  return list
    .filter((d) => d && d.mount)
    .map((d) => ({ mount: String(d.mount), totalKB: Number(d.total_kb) || 0, availKB: Number(d.avail_kb) || 0 }))
    .sort((a, b) => a.mount.localeCompare(b.mount))
}

/**
 * The disks of one hour (rdb 0121: per mount the largest size and the least
 * free of the hour), sorted by mount; [] for an hour from before the hub
 * reported disks.
 * @param {BoxStatHour | null | undefined} hour
 * @returns {{ mount: string, totalKB: number, availKB: number }[]}
 */
export function hourDisksOf(hour) {
  const list = hour && Array.isArray(hour.disks) ? hour.disks : []
  return list
    .filter((d) => d && d.mount)
    .map((d) => ({ mount: String(d.mount), totalKB: Number(d.total_kb) || 0, availKB: Number(d.avail_min_kb) || 0 }))
    .sort((a, b) => a.mount.localeCompare(b.mount))
}

/**
 * The mount nearest full (the least free share of its size, then the least
 * free), or null with no disks: what a one-cell Disk column shows.
 * @param {{ mount: string, totalKB: number, availKB: number }[]} disks
 */
export function lowestDisk(disks) {
  const share = (/** @type {{ totalKB: number, availKB: number }} */ d) => (d.totalKB > 0 ? d.availKB / d.totalKB : 1)
  let best = null
  for (const d of Array.isArray(disks) ? disks : []) {
    if (!best || share(d) < share(best) || (share(d) === share(best) && d.availKB < best.availKB)) best = d
  }
  return best
}

/**
 * One mount in one line, "/: 12 GiB free of 100 GiB" ('' for none), and every
 * mount one a line for the hover (undefined for none, so no empty tooltip).
 * @param {{ mount: string, totalKB: number, availKB: number } | null} d
 * @param {(key: string, args: Record<string, string>) => string} t vue-i18n t
 */
export function diskLine(d, t) {
  return d ? t('boxes.disk_val', { mount: d.mount, avail: formatKB(d.availKB), total: formatKB(d.totalKB) }) : ''
}

/**
 * @param {{ mount: string, totalKB: number, availKB: number }[]} disks
 * @param {(key: string, args: Record<string, string>) => string} t
 */
export function diskTitle(disks, t) {
  return Array.isArray(disks) && disks.length ? disks.map((d) => diskLine(d, t)).join('\n') : undefined
}

/**
 * A hub without the box-stats route (404) or whose store keeps no stats (501)
 * is the plain "no history yet" state, not an error.
 * @param {unknown} err
 */
export function isNoBoxStats(err) {
  const s = Number(err && /** @type {{ status?: number }} */ (err).status)
  return s === 404 || s === 501
}

/**
 * The newest sample of one box: what the middle pane's Hardware row reads
 * (CPUs, memory). null when the box never sent one.
 * @param {BoxStat[]} rows
 * @param {string} box
 * @returns {BoxStat | null}
 */
export function latestBoxStat(rows, box) {
  let best = null
  for (const r of Array.isArray(rows) ? rows : []) {
    if (!r || (box && r.box !== box)) continue
    if (!best || String(r.at) > String(best.at)) best = r
  }
  return best
}

/** @param {unknown} v @returns {Record<string, unknown> | null} */
const objOf = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? /** @type {Record<string, unknown>} */ (v) : null)
/** @param {unknown} v */
const str = (v) => (v === null || v === undefined ? '' : String(v))
/** @param {unknown} v @returns {number | null} */
const num = (v) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Number(v))
/** @param {unknown} v @returns {string[]} */
const strs = (v) => (Array.isArray(v) ? v.map(str).filter(Boolean) : [])

/**
 * The box's CURRENT state (owner ba10751d: "present also the current info"),
 * from its latest box-stats sample (a 5-minute tick), apart from the daily
 * facts: load1 against the CPUs, memory used / free, swap in use, live
 * agents and when the sample was taken. null with no sample.
 * @param {BoxStat | null | undefined} row latestBoxStat()
 */
export function currentOf(row) {
  if (!row) return null
  const total = Number(row.mem_total_kb) || 0
  const avail = Number(row.mem_avail_kb) || 0
  return {
    at: str(row.at),
    load1: Number(row.load1) || 0,
    cpus: Number(row.cpus) || 0,
    memUsedKB: Math.max(0, total - avail),
    memAvailKB: avail,
    swapUsedKB: Number(row.swap_used_kb) || 0,
    agentsLive: Number(row.agents_live) || 0,
  }
}

/**
 * The box's OS as the hub reports it (`boxes[].os`: name, version, pretty,
 * kernel, arch), or null when the hub reports none.
 * @param {{ os?: unknown } | null | undefined} detail roster.boxes[box]
 * @returns {{ name: string, version: string, pretty: string, kernel: string, arch: string } | null}
 */
export function boxOsOf(detail) {
  const o = objOf(detail && detail.os)
  if (!o) return null
  const out = { name: str(o.name), version: str(o.version), pretty: str(o.pretty), kernel: str(o.kernel), arch: str(o.arch) }
  return Object.values(out).some(Boolean) ? out : null
}

/**
 * The OS in one line for the middle pane: its pretty name, else name and
 * version, else the kernel ('' when none).
 * @param {{ name: string, version: string, pretty: string, kernel: string } | null} os
 */
export function osLine(os) {
  if (!os) return ''
  return os.pretty || [os.name, os.version].filter(Boolean).join(' ') || os.kernel
}

/**
 * The box's system snapshot (`boxes[].system`), or null when not reported.
 * Numbers stay null when a field is missing, so the pane can say so.
 * @param {{ system?: unknown } | null | undefined} detail roster.boxes[box]
 */
export function boxSystemOf(detail) {
  const o = objOf(detail && detail.system)
  if (!o) return null
  return {
    hostname: str(o.hostname),
    timezone: str(o.timezone),
    bootAt: str(o.boot_at),
    cpus: num(o.cpus),
    cpuModel: str(o.cpu_model),
    load: str(o.load),
    memTotalMB: num(o.mem_total_mb),
    memAvailMB: num(o.mem_avail_mb),
    swapTotalMB: num(o.swap_total_mb),
    swapFreeMB: num(o.swap_free_mb),
    state: str(o.state),
  }
}

/**
 * The box's network snapshot (`boxes[].network`: ips, gateway, dns), or null
 * when not reported.
 * @param {{ network?: unknown } | null | undefined} detail roster.boxes[box]
 */
export function boxNetworkOf(detail) {
  const o = objOf(detail && detail.network)
  if (!o) return null
  return { ips: strs(o.ips), gateway: str(o.gateway), dns: strs(o.dns) }
}

/**
 * When the box last collected its facts (`facts_reported_at`), '' when never.
 * @param {{ facts_reported_at?: unknown } | null | undefined} detail
 */
export function factsReportedAt(detail) {
  return str(detail && detail.facts_reported_at)
}

/**
 * The box's run-times as the hub reports them (`boxes[].runtimes`: name ->
 * version), sorted by name; [] when the hub reports none.
 * @param {{ runtimes?: unknown } | null | undefined} detail roster.boxes[box]
 * @returns {{ name: string, version: string }[]}
 */
export function boxRuntimesOf(detail) {
  const rt = detail && detail.runtimes
  if (!rt || typeof rt !== 'object' || Array.isArray(rt)) return []
  return Object.entries(/** @type {Record<string, unknown>} */ (rt))
    .filter(([name]) => name)
    .map(([name, version]) => ({ name, version: String(version ?? '') }))
    .sort((a, b) => a.name.localeCompare(b.name))
}

/**
 * Megabytes as a short binary size: 512 -> "512 MiB", 32768 -> "32 GiB".
 * '' for a missing value.
 * @param {number | null} mb
 */
export function formatMB(mb) {
  return mb === null || mb === undefined ? '' : formatKB(Number(mb) * 1024)
}

/**
 * Kilobytes as a short binary size: 16384 -> "16 MiB", 33554432 -> "32 GiB".
 * @param {number} kb
 */
export function formatKB(kb) {
  const n = Number(kb)
  if (!Number.isFinite(n) || n < 0) return ''
  const units = ['KiB', 'MiB', 'GiB', 'TiB']
  let v = n
  let i = 0
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i++
  }
  return `${v >= 10 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`
}

/**
 * A load average with two decimals ("" for a missing value).
 * @param {number} v
 */
export function formatLoad(v) {
  const n = Number(v)
  return v !== null && v !== undefined && Number.isFinite(n) ? n.toFixed(2) : ''
}

/**
 * How long ago an RFC 3339 instant was, as a compact age: "45s", "12m",
 * "3h", "5d". "" for no (or an unparsable) instant.
 * @param {string} at
 * @param {number} [now] epoch ms
 */
export function ageOf(at, now = Date.now()) {
  const t = Date.parse(String(at || ''))
  if (!Number.isFinite(t)) return ''
  const s = Math.max(0, Math.floor((now - t) / 1000))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

/**
 * One row per agent on the box for the Agents statistics: the info the hub
 * already has - id, state, when its current holder was seated (seated_at,
 * rdb 0107) and when it was last seen. The hub's live `agent_presence`
 * (state, last_seen) wins over the roster's online dot and the box's last
 * hello when it names the agent. Online first, then by id.
 * @param {{ id: string, label: string, online: boolean }[]} agents BoxRow.agents
 * @param {{ last_hello_at?: string, seated_at?: Record<string, string>, agent_presence?: Record<string, { state?: string, last_seen?: string | null }> } | null | undefined} detail roster.boxes[box]
 * @returns {{ id: string, label: string, online: boolean, seatedAt: string, lastHello: string }[]}
 */
export function agentStatRows(agents, detail) {
  const seated = (detail && detail.seated_at) || {}
  const presence = objOf(detail && detail.agent_presence) || {}
  const lastHello = str(detail && detail.last_hello_at)
  return (Array.isArray(agents) ? agents : [])
    .map((a) => {
      const p = objOf(presence[a.id])
      const online = p && p.state ? p.state === 'online' : Boolean(a.online)
      const seen = p && 'last_seen' in p ? str(p.last_seen) : lastHello
      return { id: a.id, label: a.label, online, seatedAt: str(seated[a.id]), lastHello: seen }
    })
    .sort((a, b) => (Number(b.online) - Number(a.online)) || a.id.localeCompare(b.id))
}

/**
 * The agents summary the Agents statistics lead with: total, online, offline.
 * @param {{ online: boolean }[]} rows
 */
export function agentCounts(rows) {
  const list = Array.isArray(rows) ? rows : []
  const online = list.filter((r) => r.online).length
  return { total: list.length, online, offline: list.length - online }
}

/**
 * The Hardware summary over the history: sample count, sample-weighted
 * average load1, peak load1, peak used memory and the lowest free memory.
 * null with no hours.
 * @param {BoxStatHour[]} hours
 */
export function hardwareSummary(hours) {
  const list = Array.isArray(hours) ? hours : []
  if (list.length === 0) return null
  let n = 0
  let loadSum = 0
  let loadPeak = 0
  let memPeak = 0
  let availMin = Infinity
  for (const h of list) {
    const k = Number(h.n) || 0
    n += k
    loadSum += (Number(h.load1_avg) || 0) * k
    loadPeak = Math.max(loadPeak, Number(h.load1_peak) || 0)
    memPeak = Math.max(memPeak, Number(h.mem_used_peak_kb) || 0)
    availMin = Math.min(availMin, Number(h.mem_avail_min_kb) || 0)
  }
  return { samples: n, load1Avg: n ? loadSum / n : 0, load1Peak: loadPeak, memUsedPeakKB: memPeak, memAvailMinKB: Number.isFinite(availMin) ? availMin : 0 }
}
