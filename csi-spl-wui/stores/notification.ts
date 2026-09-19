import { defineStore } from 'pinia'
import {
  escalateReason,
  channelKey,
  notifyCopy,
  loadChime,
  saveChime,
  previewUnread,
} from '~/utils/notify.mjs'
import { loadCursors, saveCursors, markReadAt } from '~/utils/read-cursor.mjs'

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
  const unread = ref<Record<string, number>>({})
  const seen = new Set<string>()

  if (import.meta.client) {
    permission.value = typeof Notification === 'undefined' ? 'unsupported' : Notification.permission
    chime.value = loadChime()
  }

  function hydrate() {
    if (!import.meta.client) return
    permission.value = typeof Notification === 'undefined' ? 'unsupported' : Notification.permission
    chime.value = loadChime()
  }

  watch(chime, (v) => {
    if (import.meta.client) saveChime(Boolean(v))
  })

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
    if (permission.value === 'granted' && typeof Notification !== 'undefined') {
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
  }

  function ingest(messages: unknown, ctx: Ctx = {}, opts: { hydrate?: boolean } = {}) {
    const rows = (Array.isArray(messages) ? messages : [messages]) as Msg[]
    const unseen = rows.filter((m) => m && m.msg_id && !seen.has(m.msg_id))
    const hydrate = opts.hydrate === true || (unseen.length > 1 && opts.hydrate !== false)
    for (const m of unseen) {
      if (!m.msg_id) continue
      seen.add(m.msg_id)
      const key = channelKey(m, ctx)
      if (hydrate) continue
      if (ctx.activeKey && ctx.activeKey === key) {
        markRead(key, m)
        if (import.meta.client && typeof document !== 'undefined' && document.hidden) {
          const reason = escalateReason(m, ctx)
          if (reason) {
            const copy = notifyCopy(m, reason)
            ping(copy.title, copy.body)
          }
        }
        continue
      }
      unread.value = { ...unread.value, [key]: (unread.value[key] || 0) + 1 }
      const reason = escalateReason(m, ctx)
      if (reason) {
        const copy = notifyCopy(m, reason)
        ping(copy.title, copy.body)
      }
    }
  }

  return {
    permission,
    chime,
    unread,
    requestPush,
    ping,
    ingest,
    markRead,
    hydrate,
    previewUnread,
  }
})
