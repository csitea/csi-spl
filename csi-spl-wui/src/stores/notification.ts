import { defineStore } from 'pinia'
import {
  escalateReason,
  channelKey,
  notifyCopyKey,
  loadChime,
  saveChime,
  loadAlerts,
  saveAlerts,
  alertsActive,
  previewUnread,
  shouldPing,
  loadMutedChannels,
} from '~/utils/notify.mjs'
import {
  cursorFromChannel,
  isUnread,
  loadCursors,
  markReadAt,
  saveCursors,
  unreadFromChannels,
} from '~/utils/read-cursor.mjs'
import { peopleLabels } from '~/utils/channel-feed.mjs'
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
    return { title: i18n.t(c.titleKey, c.params), body: c.body }
  }

  if (import.meta.client) {
    permission.value = typeof Notification === 'undefined' ? 'unsupported' : Notification.permission
    chime.value = loadChime()
    alertsEnabled.value = loadAlerts()
  }

  function hydrate() {
    if (!import.meta.client) return
    permission.value = typeof Notification === 'undefined' ? 'unsupported' : Notification.permission
    chime.value = loadChime()
    alertsEnabled.value = loadAlerts()
  }

  watch(chime, (v) => {
    if (import.meta.client) saveChime(Boolean(v))
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
      try {
        const ctx = new AudioContext()
        const osc = ctx.createOscillator()
        const gain = ctx.createGain()
        osc.frequency.value = 880
        gain.gain.value = 0.04
        osc.connect(gain)
        gain.connect(ctx.destination)
        osc.start()
        osc.stop(ctx.currentTime + 0.12)
      } catch {
        /* autoplay policies */
      }
    }
    if (alertsOn.value && typeof Notification !== 'undefined') {
      try {
        new Notification(title, { body })
      } catch {
        /* ignore */
      }
    }
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

  function bump(key: string, reason: string | null) {
    unread.value = { ...unread.value, [key]: (unread.value[key] || 0) + 1 }
    if (reason === 'mention') mentions.value = { ...mentions.value, [key]: (mentions.value[key] || 0) + 1 }
  }

  function ingest(messages: unknown, ctx: Ctx = {}, opts: { hydrate?: boolean } = {}) {
    const rows = (Array.isArray(messages) ? messages : [messages]) as Msg[]
    const unseen = rows.filter((m) => m && m.msg_id && !seen.has(m.msg_id))
    const hydrate = opts.hydrate === true || (unseen.length > 1 && opts.hydrate !== false)
    const cursors = hydrate ? loadCursors() : {}
    for (const m of unseen) {
      if (!m.msg_id) continue
      seen.add(m.msg_id)
      const key = channelKey(m, ctx)
      if (hydrate) {
        /* a (re)load: count what the stored cursor has not seen, never ping */
        if (key !== ctx.activeKey && isUnread(m, cursors[key])) {
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
    alertsEnabled,
    alertsOn,
    toggleAlerts,
    unread,
    mentions,
    requestPush,
    ping,
    ingest,
    markRead,
    markChannelRead,
    applyChannels,
    hydrate,
    previewUnread,
  }
})
