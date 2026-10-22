import type { Ref } from 'vue'
import type { SearchResult, SearchRow } from '~/utils/search.mjs'
import { flattenGroups, highlightSegments, isPlacedRow, rowAt } from '~/utils/search-results.mjs'
import type { SideHitItem } from '~/utils/side-hit-list'
import { ISSUE_CHANNEL } from '~/utils/parent-section.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { namedText, shownPerson } from '~/utils/channel-feed.mjs'

/**
 * The left search panel's hit rows (CLE-77884): the result flattened, each
 * row shaped for SideHitList (snippet with the match marked, who, where,
 * when). Pure computeds of `search.result`; moved out of the left
 * panel's SFC (r18-03), which keeps the scroll, menu and open. Reached
 * only through that lazy SFC (027 first-paint budget).
 */
export type SearchSideItemsOpts = {
  search: { readonly result: SearchResult | null }
  t: (key: string, named?: Record<string, unknown>, plural?: number) => string
  te: (key: string) => boolean
  names: Ref<Record<string, string>>
}

function groupLabel(c: SearchSideItemsOpts, type: string) { return c.t('search.group.' + type) }

function when(ts: unknown): string {
  if (!ts) return ''
  return isoDateTime(new Date(String(ts)))
}
function label(c: SearchSideItemsOpts, id: unknown, box: unknown) {
  const s = id ? String(id) : ''
  return s ? shownPerson(s, box ? String(box) : undefined, c.names.value) : ''
}
/** Where a hit lives: #channel, the Issues label for an issue's discussion (SPL-68), or a DM. */
function place(c: SearchSideItemsOpts, channel: unknown): string {
  const ch = String(channel || '')
  if (!ch) return c.t('search.in_dm')
  return ch === ISSUE_CHANNEL ? c.t('search.group.issues') : '#' + ch
}
function badgeOf(r: Record<string, unknown>): string {
  if (!isPlacedRow(r)) return ''
  if (r.type === 'messages' && r.parent_task_id && r.parent_task_id !== r.task_id) return '↳'
  return r.channel ? '#' : '@'
}

/** The meta of a non-posted hit, as the search page wrote it. */
function metaOf(c: SearchSideItemsOpts, row: SearchRow): string {
  const { t, te } = c
  const r: Record<string, unknown> = row
  switch (row.type) {
    case 'robots': return r.revoked ? t('search.revoked') : ''
    case 'channels': return r.count != null ? t('search.count_messages', { n: Number(r.count) || 0 }, Number(r.count) || 0) : ''
    case 'boxes': return Array.isArray(r.agents) ? r.agents.join(', ') : ''
    case 'tenants': {
      const role = String(r.role || '')
      const roleLabel = role && te('role.' + role) ? t('role.' + role) : ''
      return [String(r.tenant_id || ''), roleLabel, r.current ? t('search.current_tenant') : ''].filter(Boolean).join(' · ')
    }
    case 'events': return String(r.code || r.path || r.error_id || '')
    case 'issues': return [r.status, r.priority, r.assignee].filter((x) => x != null && x !== '').map(String).join(' · ')
    default: return ''
  }
}

function itemOf(c: SearchSideItemsOpts, row: SearchRow): SideHitItem {
  const r: Record<string, unknown> = row
  const segs = highlightSegments(row.display.text, row.display.highlights)
    .map((s: { text: string, mark: boolean }) => ({ text: row.type === 'messages' ? namedText(s.text, c.names.value) : s.text, mark: s.mark }))
  const base: SideHitItem = { key: row.key, type: row.type, group: groupLabel(c, row.type), segs, title: row.display.text, ts: rowAt(row) }
  if (r.msg_id && (row.type === 'messages' || row.type === 'files')) base.msgId = String(r.msg_id)
  switch (row.type) {
    case 'messages':
      return { ...base, badge: badgeOf(r), who: r.from ? { id: String(r.from), box: r.from_box ? String(r.from_box) : '' } : undefined, where: place(c, r.channel), when: when(r.received_at || r.created_at) }
    case 'topics':
      return { ...base, badge: badgeOf(r), where: [place(c, r.channel), c.t('search.count_messages', { n: Number(r.count) || 0 }, Number(r.count) || 0)].join(' · '), when: when(r.last_ts) }
    case 'files':
      return { ...base, badge: '📎', where: label(c, r.from, r.from_box), when: when(r.received_at) }
    case 'users': {
      const n = typeof r.display_name === 'string' ? r.display_name.trim() : ''
      return { ...base, who: { id: String(r.id || ''), box: r.box ? String(r.box) : '' }, segs: n ? [{ text: n, mark: false }] : [], where: metaOf(c, row) }
    }
    case 'robots':
      return { ...base, who: { id: String(r.id || ''), box: r.box ? String(r.box) : '' }, where: metaOf(c, row) }
    case 'channels':
      return { ...base, badge: '#', where: metaOf(c, row) }
    case 'events':
      return { ...base, where: metaOf(c, row), when: when(r.received_at) }
    default:
      return { ...base, where: metaOf(c, row) }
  }
}

export function useSearchSideItems(c: SearchSideItemsOpts) {
  const rows = computed(() => (c.search.result ? flattenGroups(c.search.result.groups) : []))
  const byKey = computed(() => new Map(rows.value.map((r) => [r.key, r])))
  function typeOf(label: string) {
    const g = c.search.result?.groups.find((x) => groupLabel(c, x.type) === label)
    return g ? g.type : ''
  }
  function nextOf(label: string) {
    const g = c.search.result?.groups.find((x) => groupLabel(c, x.type) === label)
    return !!(g && g.next)
  }
  const items = computed(() => rows.value.map((row) => itemOf(c, row)))
  return { rows, byKey, items, typeOf, nextOf }
}
