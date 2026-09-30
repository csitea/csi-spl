import { defineStore } from 'pinia'
import {
  escalateReason,
  channelKey,
  notifyCopyKey,
  loadChime,
  saveChime,
  notificationOptions,
  isSoundPrefKey,
  loadAlerts,
  saveAlerts,
  alertsActive,
  previewUnread,
  shouldPing,
  loadMutedChannels,
  playSound,
  loadChimeSound,
  saveChimeSound,
} from '~/utils/notify.mjs'
import {
  cursorFromChannel,
  isUnread,
  loadCursors,
  markReadAt,
  markTopicReadAt,
  saveCursors,
  topicKey,
  unreadFromChannels,
} from '~/utils/read-cursor.mjs'
import { namedText, peopleLabels, unreadFromDms } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'

type Ctx = {
  selfId?: string
  activeKey?: string
  channel?: string
  peer?: string | null
  isDm?: boolean
}

type Msg = {
  msg_id?: string
  from?: string
  to?: string
  body?: string
  kind?: string
  channel?: string | null
  from_box?: string
  ts?: string
  received_at?: string
}

export const useNotificationStore = defineStore('notification', () => {
  const permission = ref('unsupported')
  const chime = ref(false)
  /** 051: which sound the chime plays, per device (dd88348d) */
  const sound = ref('')
  /** the reader's on/off choice for browser alerts (the bell) */
  const alertsEnabled = ref(true)
  const alertsOn = computed(() => alertsActive(permission.value, alertsEnabled.value))
  const unread = ref<Record<string, number>>({})
  /** Unread HUM-* mentions per key (spec 005 FR-012 "high-priority mention indicators"). */
  const mentions = ref<Record<string, number>>({})
  const seen = new Set<string>()
  /* the global i18n instance, captured while the Nuxt app is in context (stores have no component) */
  const i18n = useNuxtApp().$i18n
  const humanNames = useHumanNames()

  /** Browser-notification title + body for one escalated message, in the active UI locale. */
  function copyFor(m: Msg, reason: string) {
    // a human sender by their chosen name (owner, 2026-09-26)
    const c = notifyCopyKey({ ...m, from: m.from ? peopleLabels([String(m.from)], humanNames.names.value) : m.from }, reason)
    /* SPL-1009: a member in the body reads their name, as in the feed */
    return { title: i18n.t(c.titleKey, c.params), body: namedText(c.body, humanNames.names.value) }
  }

  if (import.meta.client) {
    permission.value = typeof Notification === 'undefined' ? 'unsupported' : Notification.permission
    chime.value = loadChime()
    sound.value = loadChimeSound()
    alertsEnabled.value = loadAlerts()
    /* SPL-998: a second tab kept the switch it loaded and went on beeping */
    window.addEventListener('storage', (e) => {
      if (isSoundPrefKey(e.key)) hydrate()
    })
  }

  function hydrate() {
    if (!import.meta.client) return
    permission.value = typeof Notification === 'undefined' ? 'unsupported' : Notification.permission
    chime.value = loadChime()
    sound.value = loadChimeSound()
    alertsEnabled.value = loadAlerts()
  }

  watch(chime, (v) => {
    if (import.meta.client) saveChime(Boolean(v))
  })
  watch(sound, (v) => {
    if (import.meta.client && v) saveChimeSound(String(v))
  })
  watch(alertsEnabled, (v) => {
    if (import.meta.client) saveAlerts(Boolean(v))
  })

  /** The bell glyph follows the reader's switch. Messages popping do not
   *  move it. Turning it on also asks the browser, once, for permission. */
  async function toggleAlerts() {
    alertsEnabled.value = !alertsEnabled.value
    if (alertsEnabled.value && permission.value !== 'granted') await requestPush()
  }

  async function requestPush() {
    if (typeof Notification === 'undefined') return
    permission.value = await Notification.requestPermission()
  }

  function ping(title: string, body: string) {
    if (chime.value && import.meta.client) {
      /* 051: the reader's chosen sound; its AudioContext closes when it ends (CLE-35075) */
      playSound(sound.value)
    }
    if (alertsOn.value && typeof Notification !== 'undefined') {
      try {
        new Notification(title, notificationOptions(body, chime.value))
      } catch {
        /* ignore */
      }
    }
  }

  /**
   * CLE-77804 (topic 1e7d56b8): the read cursor a feed had when it was opened,
   * frozen so LiveFeed can draw the "New messages" divider while markRead
   * advances the live cursor and clears the rail badge. A feed's page calls
   * enterFeed(key) once as it opens — BEFORE selectChannel/markRead move the
   * cursor — and reads boundary[key]. `enteredKey` is a plain (non-reactive,
   * non-hydrated) marker so the freeze happens exactly once per open on the
   * client: the many markReads a single open fires (the page watch re-runs as
   * the session settles, plus the live plugin) never move it, and a genuine
   * re-open of another feed re-freezes.
   */
  const boundary = ref<Record<string, { ts: string, id: string } | null>>({})
  let enteredKey = ''

  /**
   * CLE-77804 (topic 35053f95): per-topic read snapshots — taskId -> the reply
   * total the reader had seen when they last opened that topic. The card shows
   * unread = currentTotal - seen as "<unread>/<total> >>" (topicUnread). Held in
   * the same localStorage as the cursors (t:<id>), hydrated here so a reload
   * keeps the read state. No hub round-trip: the count comes from the totals the
   * topics view already returns, and the read position is per reader, local.
   */
  const topicRead = ref<Record<string, number>>({})
  if (import.meta.client) {
    for (const [k, c] of Object.entries(loadCursors())) {
      if (k.startsWith('t:') && c && Number.isFinite((c as { count?: number }).count)) {
        topicRead.value[k.slice(2)] = Number((c as { count?: number }).count)
      }
    }
  }
  /** Mark a topic read at its current reply total (thread opened, or own reply). */
  function markTopicRead(taskId: string, count: number) {
    if (!taskId || !topicKey(taskId)) return
    const c = Math.max(0, Number(count) || 0)
    topicRead.value = { ...topicRead.value, [taskId]: c }
    if (import.meta.client) saveCursors(markTopicReadAt(loadCursors(), taskId, c))
  }
  function enterFeed(key: string) {
    if (!key || key === enteredKey) return
    enteredKey = key
    const c = loadCursors()[key]
    boundary.value = { ...boundary.value, [key]: c ? { ts: String(c.ts || ''), id: String(c.id || '') } : null }
  }

  function markRead(key: string, msg?: Msg | null) {
    if (!key) return
    saveCursors(markReadAt(loadCursors(), key, msg || undefined))
    unread.value = { ...unread.value, [key]: 0 }
    mentions.value = { ...mentions.value, [key]: 0 }
  }

  /** Read a live channel up to its hub row, keeping the hub cursor for the next read=. */
  function markChannelRead(key: string, row?: { last_ts?: string | null, last_cursor?: string | null } | null) {
    const c = cursorFromChannel(row)
    if (!key || !c) return markRead(key)
    saveCursors({ ...loadCursors(), [key]: c })
    unread.value = { ...unread.value, [key]: 0 }
    mentions.value = { ...mentions.value, [key]: 0 }
  }

  /** Hub unread (computed against our read= cursors) wins for channel keys, except the open one. */
  function applyChannels(rows: unknown, activeKey = '') {
    const hub = unreadFromChannels(rows) as Record<string, number>
    if (activeKey) delete hub[activeKey]
    unread.value = { ...unread.value, ...hub }
  }

  /** DM unread from our cursors + the ?dm=true topic rows, on load and every
   *  reconnect — the DM twin of applyChannels (the hub counts channels only, so
   *  a DM that arrived while the tab was closed showed no badge). Live bumps
   *  add between refetches; a refetch overwrites the peer with the fresh count,
   *  and the open DM is left alone (it is read as it is viewed). */
  function applyDms(topics: unknown, self = '', activeKey = '') {
    const dm = unreadFromDms(topics, loadCursors(), self) as Record<string, number>
    if (activeKey) delete dm[activeKey]
    unread.value = { ...unread.value, ...dm }
  }

  function bump(key: string, reason: string | null) {
    unread.value = { ...unread.value, [key]: (unread.value[key] || 0) + 1 }
    if (reason === 'mention') mentions.value = { ...mentions.value, [key]: (mentions.value[key] || 0) + 1 }
  }

  function ingest(messages: unknown, ctx: Ctx = {}, opts: { hydrate?: boolean } = {}) {
    const rows = (Array.isArray(messages) ? messages : [messages]) as Msg[]
    const unseen = rows.filter((m) => m && m.msg_id && !seen.has(m.msg_id))
    const hydrate = opts.hydrate === true || (unseen.length > 1 && opts.hydrate !== false)
    const cursors = hydrate ? loadCursors() : {}
    /* CLE-77804 (HUM-24, topic 311427c6): the reader's own message is never unread. */
    const self = String(ctx.selfId || '').split('@')[0]
    const isOwn = (m: Msg) => Boolean(self) && String(m.from || '').split('@')[0] === self
    for (const m of unseen) {
      if (!m.msg_id) continue
      seen.add(m.msg_id)
      const key = channelKey(m, ctx)
      if (hydrate) {
        /* a (re)load: count what the stored cursor has not seen, never ping */
        if (key !== ctx.activeKey && !isOwn(m) && isUnread(m, cursors[key])) {
          bump(key, escalateReason(m, ctx) === 'mention' ? 'mention' : null)
        }
        continue
      }
      if (ctx.activeKey && ctx.activeKey === key) {
        markRead(key, m)
        if (import.meta.client && typeof document !== 'undefined' && document.hidden && shouldPing(m, ctx, loadMutedChannels())) {
          const reason = escalateReason(m, ctx)
          if (reason) {
            const copy = copyFor(m, reason)
            ping(copy.title, copy.body)
          }
        }
        continue
      }
      /* our own echo in another channel must not raise a badge (HUM-24) */
      if (isOwn(m)) continue
      const reason = escalateReason(m, ctx)
      bump(key, reason)
      if (shouldPing(m, ctx, loadMutedChannels())) {
        const copy = copyFor(m, reason || '')
        ping(copy.title, copy.body)
      }
    }
  }

  return {
    permission,
    chime,
    sound,
    alertsEnabled,
    alertsOn,
    toggleAlerts,
    unread,
    mentions,
    boundary,
    enterFeed,
    topicRead,
    markTopicRead,
    requestPush,
    ping,
    ingest,
    markRead,
    markChannelRead,
    applyChannels,
    applyDms,
    hydrate,
    previewUnread,
  }
})
