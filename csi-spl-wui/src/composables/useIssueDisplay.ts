import type { Ref } from 'vue'
import type { IssueLabel } from '~/utils/issues.mjs'
import type { useRosterStore } from '~/stores/roster'
import type { useHumanNames } from '~/composables/useHumanNames'
import type { IssuesLive } from '~/composables/issuesPageTypes'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { shownPerson } from '~/utils/channel-feed.mjs'
import { LEVEL_SHORT } from '~/utils/issues-view.mjs'

/**
 * The issues page's display helpers: who a row names, a label's name and
 * dot, a time, a level, and the words for a refused read or write.
 * Moved out of pages/issues.vue (r16-07); the page owns the refs.
 */
export type IssueDisplayOpts = {
  roster: ReturnType<typeof useRosterStore>
  people: ReturnType<typeof useHumanNames>
  live: IssuesLive
  labels: Ref<IssueLabel[]>
  saveReason: Ref<string>
  t: (key: string, named?: Record<string, unknown>) => string
}

type HubError = { status?: number, token?: string }

function errorKey(err: HubError, which: 'list' | 'one') {
  const status = Number(err && err.status) || 0
  const token = String((err && err.token) || '')
  if (status === 401 || token === 'view_door' || token === 'unauthenticated') return 'issues.signed_out'
  if (status === 403) return 'issues.forbidden'
  if (status === 404) return which === 'list' ? 'issues.unavailable' : 'issues.not_found'
  if (token === 'epic_required') return 'issues.err_epic_required'
  if (token === 'bad_epic') return 'issues.err_bad_epic'
  if (token === 'epic_has_issues') return 'issues.err_epic_has_issues'
  if (status === 503 || token === 'unavailable') return 'issues.unavailable'
  return which === 'list' ? 'issues.load_failed' : 'issues.save_failed'
}

export function useIssueDisplay(o: IssueDisplayOpts) {
  function boxOf(id: string) {
    return o.roster.people.find((p) => p.id === id)?.box || ''
  }
  function person(id: string) {
    return id ? shownPerson(id, boxOf(id), o.people.names.value) : ''
  }
  function labelText(id: string) {
    return o.labels.value.find((l) => l.id === id)?.name || id
  }
  function dotStyle(id: string) {
    const color = o.labels.value.find((l) => l.id === id)?.color || ''
    return /^#[0-9a-f]{6}$/i.test(color) ? { background: color } : {}
  }
  function when(rfc: string) {
    return isoDateTime(rfc)
  }
  function levelShort(n: number) {
    return LEVEL_SHORT[n] || ''
  }
  function meId() {
    return o.roster.self?.id || o.live.identity.value || ''
  }
  /* a refused write: the page's own words, or the hub's reason (never a bare
     "That change did not save" when the hub said why) */
  function failKey(e: unknown): string {
    const key = errorKey(e as HubError, 'one')
    o.saveReason.value = String((e as { detail?: string })?.detail || '')
    return key === 'issues.save_failed' && o.saveReason.value ? 'issues.save_failed_reason' : key
  }
  function refusedText(key: string, e: unknown): string {
    const reason = String((e as { detail?: string })?.detail || '')
    return key === 'issues.save_failed' && reason ? o.t('issues.save_failed_reason', { reason }) : o.t(key)
  }
  return { boxOf, person, labelText, dotStyle, when, levelShort, meId, errorKey, failKey, refusedText }
}
