import { defineStore, skipHydrate } from 'pinia'
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
  alertState,
  previewUnread,
  dmBadgeText,
  dmTotalText,
  shouldPing,
  offScreenReply,
  loadMutedChannels,
  playSound,
  loadChimeSound,
  saveChimeSound,
  showAlert,
  pingThrottle,
  notificationTarget,
  PENDING_OPEN_KEY,
} from '~/utils/notify.mjs'
import { isAiMessage, isViewersOwn } from '~/utils/typed-by.mjs'
import {
  cursorFromChannel,
  isUnread,
  loadCursors,
  markReadAt,
  markTopicReadAt,
  ownReplyReadAt,
  replyTopicsOf,
  saveCursors,
  topicKey,
  unreadFromChannels,
} from '~/utils/read-cursor.mjs'
import { dmPeerOf, dmTotalsFromDms, namedText, peopleLabels, unreadFromDms } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'

type Ctx = {
  selfId?: string
  activeKey?: string
  channel?: string
  peer?: string | null
  isDm?: boolean
  /** the open feed's messages, to tell a reply from a new topic (offScreenReply) */
  feed?: Msg[]
  /** task ids whose thread is on screen (the right pane, a /t/ page, the lobby room) */
  openTopics?: string[]
  /** spec 096 T005: the reader's own status (shouldPing) */
  status?: { state?: string, pauseNotify?: boolean, until?: string }
}

type Msg = {
  msg_id?: string
  task_id?: string
  parent_task_id?: string | null
  topic_row?: boolean
  is_parent?: 0 | 1
  from?: string
  to?: string
  body?: string
  kind?: string
  channel?: string | null
  from_box?: string
  typed_by?: string
  ts?: string
  received_at?: string
}

type NuxtApp = ReturnType<typeof useNuxtApp>
type I18n = NuxtApp['$i18n']
type HumanNames = ReturnType<typeof useHumanNames>
type Counts = Ref<Record<string, number>>

function platform() {
  if (!import.meta.client || typeof navigator === 'undefined') return {}
  const standalone = Boolean((navigator as Navigator & { standalone?: boolean }).standalone)
    || (typeof matchMedia === 'function' && matchMedia('(display-mode: standalone)').matches)
  return { ua: navigator.userAgent, maxTouchPoints: navigator.maxTouchPoints, standalone }
}

/** The reader is not looking at this tab: hidden, or another window in front. */
function away() {
  if (typeof document === 'undefined') return false
  if (document.hidden) return true
  return typeof document.hasFocus === 'function' && !document.hasFocus()
}

/** CLE-77890: a tapped alert opens its message (sw.js on Android, onclick on a desktop). */
function openTarget(data: { url?: string } | null | undefined) {
  const url = String((data && data.url) || '')
  if (!url.startsWith('/') || url.startsWith('//')) return
  /* kept until the route is there, so a reload in between (build-watch on
     becoming visible) opens it again on boot (plugins/notify-open) */
  try { sessionStorage.setItem(PENDING_OPEN_KEY, JSON.stringify({ url, at: Date.now() })) } catch { /* private mode */ }
  void Promise.resolve(navigateTo(url)).finally(() => {
    try { sessionStorage.removeItem(PENDING_OPEN_KEY) } catch { /* private mode */ }
  })
}

/** The browser's permission, the chime switch, its sound and the reader's bell switch. */
type Prefs = readonly [Ref<string>, Ref<boolean>, Ref<string>, Ref<boolean>]

/** The browser's permission and this device's sound prefs, read and asked for. */
function permissionSteps(prefs: Prefs) {
  const [permission, chime, sound, alertsEnabled] = prefs

  function readPermission() {
    permission.value = typeof Notification === 'undefined' ? 'unsupported' : Notification.permission
  }

  async function watchPermission() {
    try {
      const status = await navigator.permissions?.query({ name: 'notifications' as PermissionName })
      if (status) status.onchange = () => readPermission()
    } catch {
      /* Safari before 16 has no notifications permission query */
    }
  }

  async function requestPush() {
    if (typeof Notification === 'undefined') return
    permission.value = await Notification.requestPermission()
  }

  /**
   * HUM-24 (311427c6): the bell defaults ON, but a browser asks for permission
   * only from a click, so a reader who never touched the bell had "alerts on"
   * and a browser that was never asked. The first click or key press anywhere
   * asks, once per page load, while the bell is on and the browser undecided.
   */
  function askOnFirstGesture() {
    const ask = () => {
      window.removeEventListener('pointerdown', ask, true)
      window.removeEventListener('keydown', ask, true)
      readPermission()
      /* an unprompted ask: a browser that throws instead of answering leaves `permission` as it was, and the bell asks again */
      if (alertsEnabled.value && permission.value === 'default') void requestPush().catch(() => {})
    }
    window.addEventListener('pointerdown', ask, true)
    window.addEventListener('keydown', ask, true)
  }

  function hydrate() {
    if (!import.meta.client) return
    readPermission()
    chime.value = loadChime()
    sound.value = loadChimeSound()
    alertsEnabled.value = loadAlerts()
  }

  if (import.meta.client) {
    hydrate()
    /* SPL-998: a second tab kept the switch it loaded and went on beeping */
    window.addEventListener('storage', (e) => {
      if (isSoundPrefKey(e.key)) hydrate()
    })
    /* HUM-24 (311427c6): a permission granted or revoked in the browser's
       site settings shows when the reader comes back, without a reload */
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) readPermission()
    })
    void watchPermission()
    askOnFirstGesture()
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
  return [readPermission, requestPush, hydrate] as const
}

type Permission = ReturnType<typeof permissionSteps>

/** The bell, the Settings test alert, and the ping a message raises. */
function alertSteps(prefs: Prefs, alertsOn: ComputedRef<boolean>, nuxtApp: NuxtApp, i18n: I18n, humanNames: HumanNames, steps: Permission) {
  const [permission, chime, sound, alertsEnabled] = prefs
  const [readPermission, requestPush] = steps

  /** The bell glyph follows the reader's switch. Messages popping do not
   *  move it. Turning it on also asks the browser, once, for permission. */
  async function toggleAlerts() {
    alertsEnabled.value = !alertsEnabled.value
    if (alertsEnabled.value && permission.value !== 'granted') await requestPush()
  }

  /**
   * HUM-24 (311427c6): Settings' "send a test notification" - the same path a
   * new message takes (showAlert, the worker fallback on Android), so a reader
   * can see for themselves whether this browser and the operating system let
   * an alert through. Asks for permission first when the browser is undecided.
   * @returns 'shown' | 'failed' | the alertState that stops it
   */
  async function testAlert() {
    if (permission.value === 'default') await requestPush()
    readPermission()
    const blocker = alertState(permission.value, true, platform())
    if (blocker !== 'on') return blocker
    if (chime.value && import.meta.client) playSound(sound.value)
    const title = i18n.t('notify.test_title')
    const body = i18n.t('notify.test_body')
    const tag = 'spool-test'
    return (await showAlert(title, notificationOptions(body, chime.value, tag))) ? 'shown' : 'failed'
  }

  /* bug A: a burst of replies plays one chime, not one per message */
  const chimeGate = pingThrottle(2000)

  function ping(title: string, body: string, tag = '', m: Msg | null = null) {
    if (chime.value && import.meta.client && chimeGate()) {
      /* 051: the reader's chosen sound; its AudioContext closes when it ends (CLE-35075) */
      playSound(sound.value)
    }
    if (alertsOn.value && typeof Notification !== 'undefined') {
      /* bug A: Android takes it only through the service worker (showAlert) */
      const data = m ? notificationTarget(m, (p: string) => nuxtApp.$localePath(p)) : undefined
      void showAlert(title, notificationOptions(body, chime.value, tag, data), { onOpen: openTarget })
    }
  }

  /** Browser-notification title + body for one escalated message, in the active UI locale. */
  function copyFor(m: Msg, reason: string) {
    // a human sender by their chosen name (owner, 2026-09-26)
    /* specs/058 (CLE-77932): an agent is <ID>@<box> - CLE-001 runs on every box */
    const agentBox = m.from_box && !/^(HUM|GST)-/.test(String(m.from || '')) ? `@${m.from_box}` : ''
    const who = m.from ? peopleLabels([String(m.from) + agentBox], humanNames.names.value) : m.from
    /* HUM-24 (csitea ba4696c1): an AI agent's alert carries the robot mark, as its card carries the AI badge */
    const c = notifyCopyKey({ ...m, from: who && isAiMessage(m) ? `\u{1F916} ${who}` : who }, reason)
    /* SPL-1009: a member in the body reads their name, as in the feed */
    return { title: i18n.t(c.titleKey, c.params), body: namedText(c.body, humanNames.names.value) }
  }

  /** One message's alert, on its feed's key. */
  function pingFor(m: Msg, reason: string, key: string) {
    const copy = copyFor(m, reason)
    ping(copy.title, copy.body, key, m)
  }

  return [toggleAlerts, testAlert, ping, pingFor] as const
}

type Alerts = ReturnType<typeof alertSteps>

/**
 * CLE-77804 (topic 35053f95): per-topic read snapshots — taskId -> the reply
 * total the reader had seen when they last opened that topic. The card shows
 * unread = currentTotal - seen as "<unread>/<total> >>" (topicUnread). Held in
 * the same localStorage as the cursors (t:<id>), hydrated here so a reload
 * keeps the read state. No hub round-trip: the count comes from the totals the
 * topics view already returns, and the read position is per reader, local.
 */
function topicMarks(read: Record<string, number>, cursors: Record<string, unknown>, held: Record<string, unknown> = {}) {
  for (const [k, c] of Object.entries(cursors)) {
    if (k.startsWith('t:') && c && !held[k] && Number.isFinite((c as { count?: number }).count)) read[k.slice(2)] = Number((c as { count?: number }).count)
  }
  return read
}

type Boundary = Ref<Record<string, { ts: string, id: string } | null>>

/** A topic card's read mark: read, set, and moved by the reader's own replies and a channel's open. */
function topicSteps(boundary: Boundary) {
  const topicRead = ref<Record<string, number>>(import.meta.client ? topicMarks({}, loadCursors()) : {})

  /** CLE-77804: the unread part of a topic card's "<unread>/<total>" - the
   *  total minus what the reader had seen when they last read it (0 if never,
   *  so an untouched topic shows a plain total). Every card reads this one rule;
   *  `seen`: a mark frozen earlier (an open thread pane, from before it read). */
  function topicUnread(taskId: string, total: number, seen: number | undefined = topicRead.value[taskId]) {
    return Number.isFinite(seen) ? Math.max(0, total - Number(seen)) : 0
  }
  /** Mark a topic read at its current reply total (thread opened, or own reply).
   *  `ownMsgId`: the own reply that total already counts, so its echo never counts it twice (CLE-77889). */
  function markTopicRead(taskId: string, count: number, ownMsgId = '') {
    if (!taskId || !topicKey(taskId)) return
    const c = Math.max(0, Number(count) || 0)
    topicRead.value = { ...topicRead.value, [taskId]: c }
    if (import.meta.client) saveCursors(markTopicReadAt(loadCursors(), taskId, c, ownMsgId))
  }

  /** CLE-77889: the reader's own reply (another tab or device, a terminal line) is seen, never "1/N" new. */
  function ownReplyRead(m: Msg) {
    if (!import.meta.client) return
    const before = loadCursors()
    let next = before
    for (const id of replyTopicsOf(m) as string[]) next = ownReplyReadAt(next, id, m)
    if (next === before) return
    saveCursors(next)
    const read = { ...topicRead.value }
    for (const id of replyTopicsOf(m) as string[]) {
      const c = next[topicKey(id)] as { count?: number } | undefined
      if (c && Number.isFinite(c.count)) read[id] = Number(c.count)
    }
    topicRead.value = read
  }
  /**
   * CLE-77930 (owner, t1 bf737f3f): as a channel opens, a thread with replies
   * after the frozen boundary and no cursor of its own is marked AT that
   * boundary, so its card shows them as "<new>/<total>" instead of the badge's
   * new lines vanishing when markRead clears it (seedTopicCursors).
   */
  async function seedTopics(key: string, messages: unknown[], totalOf: (taskId: string) => number, selfId = '') {
    if (!import.meta.client || !key) return
    const { seedTopicCursors } = await import('~/utils/topic-seed.mjs')
    const before = loadCursors()
    const next = seedTopicCursors(before, boundary.value[key], messages, totalOf, selfId)
    if (next === before) return
    saveCursors(next)
    topicRead.value = topicMarks({ ...topicRead.value }, next, before)
  }

  return [topicRead, topicUnread, markTopicRead, ownReplyRead, seedTopics] as const
}

/**
 * A feed's read cursor, moved as it is read. CLE-77804 (topic 1e7d56b8): the
 * cursor a feed had when it was opened is frozen in `boundary`, so LiveFeed can
 * draw the "New messages" divider while markRead advances the live cursor and
 * clears the rail badge. A feed's page calls enterFeed(key) once as it opens —
 * BEFORE selectChannel/markRead move the cursor — and reads boundary[key].
 * `enteredKey` is a plain (non-reactive, non-hydrated) marker so the freeze
 * happens exactly once per open on the client: the many markReads a single
 * open fires (the page watch re-runs as the session settles, plus the live
 * plugin) never move it, and a genuine re-open of another feed re-freezes.
 */
function readSteps(unread: Counts, mentions: Counts, boundary: Boundary) {
  let enteredKey = ''

  function enterFeed(key: string) {
    if (!key || key === enteredKey) return
    enteredKey = key
    const c = loadCursors()[key]
    boundary.value = { ...boundary.value, [key]: c ? { ts: String(c.ts || ''), id: String(c.id || '') } : null }
  }

  /** A read key's rail badge and mention mark go to 0. */
  function clear(key: string) {
    unread.value = { ...unread.value, [key]: 0 }
    mentions.value = { ...mentions.value, [key]: 0 }
  }

  function markRead(key: string, msg?: Msg | null) {
    if (!key) return
    saveCursors(markReadAt(loadCursors(), key, msg || undefined))
    clear(key)
  }

  /** Read a live channel up to its hub row, keeping the hub cursor for the next read=. */
  function markChannelRead(key: string, row?: { last_ts?: string | null, last_cursor?: string | null } | null) {
    const c = cursorFromChannel(row)
    if (!key || !c) return markRead(key)
    saveCursors({ ...loadCursors(), [key]: c })
    clear(key)
  }

  return [enterFeed, markRead, markChannelRead] as const
}

/** The rail counts: hub unread on (re)load, DM totals, and the pings a reconnect's catch-up owes. */
function countSteps(unread: Counts, dmTotal: Counts, i18n: I18n, humanNames: HumanNames, ping: Alerts[2]) {
  const totalSeen = new Set<string>()

  /**
   * HUM-24 round 2 (311427c6, "notification for new messages does not work"):
   * what arrived while the socket was down - a hub redeploy, a network blip, a
   * hidden tab whose reconnect timer Chrome throttles to once a minute - came
   * back only as rail badges from the catch-up read, never as a ping. After a
   * reconnect, the keys whose hub count grew past ours ping once together.
   * The open feed counts only while the reader is away from the tab.
   */
  function pingMissed(counts: Record<string, number>, activeKey = '') {
    if (!import.meta.client) return
    const muted = new Set(loadMutedChannels())
    const grew = Object.entries(counts).filter(([k, n]) => n > (unread.value[k] || 0)
      && (k !== activeKey || away())
      && !(k.startsWith('ch:') && muted.has(k.slice(3))))
    if (!grew.length) return
    const added = grew.reduce((sum, [k, n]) => sum + n - (unread.value[k] || 0), 0)
    const names = grew.map(([k]) => (k.startsWith('dm:') ? peopleLabels([k.slice(3)], humanNames.names.value) : `#${k.slice(3)}`))
    const title = grew.length === 1 && grew[0][0].startsWith('dm:')
      ? i18n.t('notify.title_dm', { from: names[0] })
      : i18n.t('notify.title_other', { from: names.slice(0, 3).join(', ') + (names.length > 3 ? ' …' : '') })
    ping(title, `+${added}`, 'spool-missed')
  }

  /** Hub unread (computed against our read= cursors) wins for channel keys, except the open one.
   *  `catchUp`: the read after a reconnect, which pings what the socket missed (pingMissed). */
  function applyChannels(rows: unknown, activeKey = '', opts: { catchUp?: boolean } = {}) {
    const hub = unreadFromChannels(rows) as Record<string, number>
    if (opts.catchUp) pingMissed(hub, activeKey)
    if (activeKey) delete hub[activeKey]
    unread.value = { ...unread.value, ...hub }
  }

  /** DM unread from the ?dm=true topic rows (the hub's dm_counts against our
   *  dm_read= cursors, or an older hub's inline page against loadCursors), on
   *  load and every reconnect — the DM twin of applyChannels. Live bumps
   *  add between refetches; a refetch overwrites the peer with the fresh count,
   *  and the open DM is left alone (it is read as it is viewed). */
  function applyDms(topics: unknown, self = '', activeKey = '', opts: { catchUp?: boolean } = {}) {
    const dm = unreadFromDms(topics, loadCursors(), self) as Record<string, number>
    if (opts.catchUp) pingMissed(dm, activeKey)
    if (activeKey) delete dm[activeKey]
    unread.value = { ...unread.value, ...dm }
    /* CLE-77845: the hub's totals win on every (re)load; live frames add between */
    dmTotal.value = { ...dmTotal.value, ...(dmTotalsFromDms(topics, self) as Record<string, number>) }
  }

  /** One live frame: a DM (ours or theirs) adds one to its peer's total, once per msg_id. */
  function countDmLive(m: Msg | null | undefined, self = '') {
    if (!m || m.channel || !m.msg_id || totalSeen.has(m.msg_id)) return
    totalSeen.add(m.msg_id)
    const peer = dmPeerOf(m, self) as string
    if (!peer) return
    const key = `dm:${peer}`
    dmTotal.value = { ...dmTotal.value, [key]: (dmTotal.value[key] || 0) + 1 }
  }

  /** The rail badge of a DM: "<new>/<total>", '' when nothing is new. */
  function dmBadge(key: string) {
    return dmBadgeText(unread.value[key] || 0, dmTotal.value[key] || 0) as string
  }

  /** CLE-77873: a DM with nothing new shows its plain total ("7"); '' when unknown. */
  function dmTotalBadge(key: string) {
    return unread.value[key] ? '' : dmTotalText(dmTotal.value[key] || 0) as string
  }

  return [applyChannels, applyDms, countDmLive, dmBadge, dmTotalBadge] as const
}

/** Live and loaded messages: count what the reader has not seen, and ping what needs them. */
function ingestStep(unread: Counts, mentions: Counts, pingFor: Alerts[3], ownReplyRead: (m: Msg) => void, markRead: (key: string, msg?: Msg | null) => void) {
  const seen = new Set<string>()

  function bump(key: string, reason: string | null) {
    unread.value = { ...unread.value, [key]: (unread.value[key] || 0) + 1 }
    if (reason === 'mention') mentions.value = { ...mentions.value, [key]: (mentions.value[key] || 0) + 1 }
  }

  return function ingest(messages: unknown, ctx: Ctx = {}, opts: { hydrate?: boolean } = {}) {
    const rows = (Array.isArray(messages) ? messages : [messages]) as Msg[]
    const unseen = rows.filter((m) => m && m.msg_id && !seen.has(m.msg_id))
    const hydrate = opts.hydrate === true || (unseen.length > 1 && opts.hydrate !== false)
    const cursors = hydrate ? loadCursors() : {}
    /* CLE-77804 (HUM-24, topic 311427c6): the reader's own message is never unread. */
    const isOwn = (m: Msg) => isViewersOwn(m, ctx.selfId)
    for (const m of unseen) {
      if (!m.msg_id) continue
      seen.add(m.msg_id)
      if (isOwn(m)) ownReplyRead(m)
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
        /* the open feed signals while the reader is away from the tab, or
           for a reply whose thread is not open (HUM-24, offScreenReply) */
        const unseenHere = away() || offScreenReply(m, ctx.feed || rows, ctx.openTopics || [])
        if (import.meta.client && unseenHere && shouldPing(m, ctx, loadMutedChannels())) pingFor(m, escalateReason(m, ctx) || '', key)
        continue
      }
      /* our own echo in another channel must not raise a badge (HUM-24) */
      if (isOwn(m)) continue
      const reason = escalateReason(m, ctx)
      bump(key, reason)
      if (shouldPing(m, ctx, loadMutedChannels())) pingFor(m, reason || '', key)
    }
  }
}

export const useNotificationStore = defineStore('notification', () => {
  const permission = ref('unsupported')
  const chime = ref(false)
  /** 051: which sound the chime plays, per device (dd88348d) */
  const sound = ref('')
  /** the reader's on/off choice for browser alerts (the bell) */
  const alertsEnabled = ref(true)
  const prefs = [permission, chime, sound, alertsEnabled] as const
  const alertsOn = computed(() => alertsActive(permission.value, alertsEnabled.value))
  /** HUM-24 (311427c6): why an alert can or cannot fire here - on / off / ask / blocked / install / unsupported */
  const alertStatus = computed(() => alertState(permission.value, alertsEnabled.value, platform()))
  const unread = ref<Record<string, number>>({})
  /** CLE-77845: every message per DM key (`dm:<peer>`), for the "<new>/<total>" rail badge. */
  const dmTotal = ref<Record<string, number>>({})
  /** Unread HUM-* mentions per key (spec 005 FR-012 "high-priority mention indicators"). */
  const mentions = ref<Record<string, number>>({})
  /* the global i18n instance, captured while the Nuxt app is in context (stores have no component) */
  const nuxtApp = useNuxtApp()
  const i18n = nuxtApp.$i18n
  const humanNames = useHumanNames()
  const steps = permissionSteps(prefs)
  const [, requestPush, hydrate] = steps
  const [toggleAlerts, testAlert, ping, pingFor] = alertSteps(prefs, alertsOn, nuxtApp, i18n, humanNames, steps)
  /** CLE-77804: each feed's read cursor as it was opened (readSteps) */
  const boundary = ref<Record<string, { ts: string, id: string } | null>>({})
  const [topicRead, topicUnread, markTopicRead, ownReplyRead, seedTopics] = topicSteps(boundary)
  const [enterFeed, markRead, markChannelRead] = readSteps(unread, mentions, boundary)
  const [applyChannels, applyDms, countDmLive, dmBadge, dmTotalBadge] = countSteps(unread, dmTotal, i18n, humanNames, ping)
  const ingest = ingestStep(unread, mentions, pingFor, ownReplyRead, markRead)

  return {
    /* HUM-24 (t1 cd9b0f47): '/' is prerendered, and its payload's server
       values (chime off, permission 'unsupported') replaced what this
       browser had stored - and the chime watch then SAVED the off. Every
       load of the home page switched the reader's sound off. These are the
       browser's, not the page's (as topicRead below). */
    permission: skipHydrate(permission),
    chime: skipHydrate(chime),
    sound: skipHydrate(sound),
    alertsEnabled: skipHydrate(alertsEnabled),
    alertsOn,
    alertStatus,
    toggleAlerts,
    testAlert,
    unread,
    mentions,
    boundary,
    enterFeed,
    seedTopics,
    /* Owner (HUM-10, t1 7ef63cfc): '/' is prerendered, and its payload's empty
       map replaced the marks read from localStorage above - a tab opened there
       drew every topic card a plain total. They are this browser's, not the page's. */
    topicRead: skipHydrate(topicRead),
    topicUnread,
    markTopicRead,
    requestPush,
    ping,
    openTarget,
    ingest,
    markRead,
    markChannelRead,
    applyChannels,
    applyDms,
    dmTotal,
    countDmLive,
    dmBadge,
    dmTotalBadge,
    hydrate,
    previewUnread,
  }
})
