/**
 * How a Flow row becomes a left-list item (r21-06, moved out of FlowList.vue):
 * a message entry or, in Mine, a folded line (spec 130). Pure mapping over
 * `flow.visible`: no API call, no emit, no DOM. FlowList passes `isLine` and
 * `lineSummary` on to useFlowLineMenu.
 */
import type { Ref } from 'vue'
import { useChannelStore } from '~/stores/channel'
import { useNotificationStore } from '~/stores/notification'
import { flowUnread } from '~/utils/flow-entries.mjs'
import type { FlowEntry } from '~/utils/flow-entries.mjs'
import { FLOW_LINE_GLYPH } from '~/utils/flow-fold.mjs'
import type { FlowLine } from '~/utils/flow-fold.mjs'
import type { SideHitItem } from '~/utils/side-hit-list'
import { loadCursors } from '~/utils/read-cursor.mjs'
import { formatMsgListTs, phoneCardTime, shownPerson } from '~/utils/channel-feed.mjs'
import { isAiMessage } from '~/utils/typed-by.mjs'
import type { useFlowStore } from '~/stores/flow'
import type { useHumanNames } from '~/composables/useHumanNames'

export type FlowListItemsOptions = {
  flow: ReturnType<typeof useFlowStore>
  people: ReturnType<typeof useHumanNames>
  now: Ref<number>
  t: (key: string, params?: Record<string, unknown>) => string
}

type ItemsCtx = FlowListItemsOptions & { channelName: (id: string) => string }

function personOf(label: string) {
  const at = label.indexOf('@')
  return at > 0 ? { id: label.slice(0, at), box: label.slice(at + 1) } : { id: label, box: '' }
}

function placeTitle(t: ItemsCtx['t'], e: FlowEntry, place: string) {
  if (e.event === 'mention') return t('flow.mention_in', { place })
  return e.reply ? t('flow.reply_in', { place }) : place
}

/** Mine's folded lines (spec 130): the test, the summary and the list item. */
function flowLines(c: ItemsCtx) {
  const { flow, people, now, t, channelName } = c

  /** Mine shows the hub's folded lines (spec 130); the mock's whole-feed fixture still shows entries. */
  function isLine(r: FlowLine | FlowEntry | null | undefined): r is FlowLine {
    return Boolean(r && flow.mineOn)
  }

  /** The place a topic line is in: its channel, else the DM's first other id. */
  function linePlace(l: FlowLine) {
    if (l.channel) return '#' + channelName(String(l.channel))
    const peer = personOf(String(l.where || (l.ids && l.ids[0]) || ''))
    return peer.id ? shownPerson(peer.id, peer.box, people.names.value) : ''
  }

  /**
   * The line's one-line summary (spec 130 section 2.1): the count when > 1,
   * the topic title, up to two ids then "+N"; a release line its version span.
   * The kind leads as the badge, the time sits on the right.
   */
  function lineSummary(l: FlowLine) {
    if (l.kind === 'release') {
      return l.version_from && l.version_from !== l.version_to
        ? t('flow.line_release', { from: l.version_from, to: l.version_to, n: l.versions })
        : String(l.version_to || '')
    }
    const ids = (l.ids || []).map((id) => {
      const p = personOf(id)
      return shownPerson(p.id, p.box, people.names.value)
    })
    const who = ids.length ? ' · ' + ids.join(', ') + (l.ids_more ? ` +${l.ids_more}` : '') : ''
    const title = l.title || l.text || '📎'
    return (l.count > 1 ? l.count + ' ' : '') + t('flow.line_in', { title }) + who
  }

  function lineItem(l: FlowLine): SideHitItem {
    const summary = lineSummary(l)
    return {
      key: l.key,
      msgId: l.msg_id || '',
      type: l.kind,
      badge: FLOW_LINE_GLYPH[l.kind] || '',
      where: l.kind === 'release' ? t('flow.kind.release') : linePlace(l),
      when: phoneCardTime(formatMsgListTs(l.at), l.at, now.value),
      text: summary,
      title: t('flow.kind.' + l.kind) + ' · ' + summary + (l.title && l.text ? '\n' + l.text : ''),
      unread: l.unread && !flow.opened.has(l.key),
      fold: true,
    }
  }

  return { isLine, lineSummary, lineItem }
}

/** A message entry's list item: its place, badge, author and unread dot. */
function entryItem(c: ItemsCtx, e: FlowEntry, cursors: ReturnType<typeof loadCursors>): SideHitItem {
  const { flow, people, now, t, channelName } = c
  let where: string
  if (e.kind === 'channel') {
    where = channelName(String(e.channel))
  } else {
    const peer = personOf(e.where)
    where = shownPerson(peer.id, peer.box, people.names.value)
  }
  const place = (e.kind === 'channel' ? '#' : '@') + where
  const reply = e.event ? e.event === 'reply' : e.reply
  return {
    key: e.key,
    msgId: e.msg_id,
    type: e.event === 'mention' ? 'mention' : reply ? 'reply' : e.kind,
    badge: e.event === 'mention' ? '@' : reply ? '↳' : e.kind === 'channel' ? '#' : '@',
    who: { id: e.from, box: e.from_box },
    ai: isAiMessage(e),
    where,
    when: phoneCardTime(formatMsgListTs(e.at), e.at, now.value),
    text: e.text || '📎',
    title: placeTitle(t, e, place) + '\n' + e.text,
    unread: flowUnread(e, cursors, flow.opened),
  }
}

export function useFlowListItems(o: FlowListItemsOptions) {
  const { flow } = o
  const channel = useChannelStore()
  const notes = useNotificationStore()

  /* the unread dot reads the same local cursors the badges do; a badge cleared
     elsewhere (notes.unread changes) re-reads them */
  const cursors = computed(() => {
    void notes.unread
    return import.meta.client ? loadCursors() : {}
  })

  function channelName(id: string) {
    const c = channel.channels.find((r) => String(r.channel_id || '') === id)
    return String((c && c.name) || id)
  }

  const ctx: ItemsCtx = { ...o, channelName }
  const { isLine, lineSummary, lineItem } = flowLines(ctx)

  const items = computed<SideHitItem[]>(() => flow.visible.map((r: FlowLine | FlowEntry) => {
    if (isLine(r)) return lineItem(r)
    return entryItem(ctx, r as FlowEntry, cursors.value)
  }))

  return { items, isLine, lineSummary }
}
