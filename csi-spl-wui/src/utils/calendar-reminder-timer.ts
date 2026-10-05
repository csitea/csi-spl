// Spec 089 T006 (owner D4): the calendar reminder timer, its own chunk.
// plugins/calendar-reminders.client.ts loads it once the app is ready and
// the session is in. It reads the viewer's reminders (GET
// /v1/calendar/reminders, the last and next 24 h) on start, on focus, after
// a calendar change and hourly, and sets ONE browser timer for the next one
// due. The pop-up's code is fetched the first time a reminder shows. No
// agent, no AI, no spool message, no notification call: a dismiss is
// remembered in this browser only (utils/calendar-reminders.mjs).
import { h, render, type App, type ComponentPublicInstance } from 'vue'
import {
  CALENDAR_CHANGED_EVENT, REMINDER_DISMISSED_KEY, REMINDER_FOCUS_GAP_MS, REMINDER_REFRESH_MS,
  dueReminders, parseDismissed, readReminders, reminderWindow, withDismissed,
} from '~/utils/calendar-reminders.mjs'

type Reminder = CalendarReminder
type Popup = ComponentPublicInstance & { set(list: Reminder[]): void }
type Api = { mock: boolean, base: string, token: string, credentials: RequestCredentials }
export type ReminderTimer = { start(): void, stop(): void }

/* setTimeout's own ceiling; a later reminder is re-armed by the hourly read */
const MAX_DELAY = 2 ** 31 - 1

function loadDismissed(): Record<string, number> {
  try { return parseDismissed(localStorage.getItem(REMINDER_DISMISSED_KEY), Date.now()) } catch { return {} }
}

function saveDismissed(ev: Reminder) {
  try { localStorage.setItem(REMINDER_DISMISSED_KEY, JSON.stringify(withDismissed(loadDismissed(), ev))) } catch { /* memory only: shows again on the next read */ }
}

/** One read of the viewer's reminders in [from, to); null when the hub has none to give. */
async function fetchReminders(api: Api, from: string, to: string): Promise<unknown> {
  if (api.mock) return (await import('~/utils/calendar-reminders-mock.mjs')).sharedMockReminders().reminders(from, to)
  const headers: Record<string, string> = { accept: 'application/json' }
  if (api.token) headers.authorization = `Bearer ${api.token}`
  const q = new URLSearchParams({ from, to })
  const r = await fetch(`${api.base}/v1/calendar/reminders?${q}`, {
    credentials: api.credentials, cache: 'no-cache', headers, signal: AbortSignal.timeout(15000),
  })
  /* an older hub without the route, a role without topics.read: no reminders */
  if (!r.ok) return null
  return r.json()
}

/** The pop-up's chunk, mounted once into its own node with the app's context (i18n, router, pinia). */
function mountPopup(app: App, onDismiss: (ev: Reminder) => void): Promise<Popup> {
  return import('~/components/CalendarReminderPopup.vue').then((m) => {
    const host = document.createElement('div')
    document.body.appendChild(host)
    const vnode = h(m.default, { onDismiss })
    vnode.appContext = app._context
    render(vnode, host)
    return vnode.component!.exposed as unknown as Popup
  })
}

export function createReminderTimer(app: App, api: Api): ReminderTimer {
  let list: Reminder[] = []
  let timer: ReturnType<typeof setTimeout> | null = null
  let lastRead = 0
  let seq = 0
  let popup: Promise<Popup> | null = null
  let active = false

  function dismiss(ev: Reminder) {
    saveDismissed(ev)
    list = list.filter((r) => r !== ev)
    tick()
  }

  function tick() {
    if (timer) { clearTimeout(timer); timer = null }
    const { show, next } = dueReminders(list, Date.now(), loadDismissed())
    if (show.length || popup) {
      popup ||= mountPopup(app, dismiss)
      void popup.then((p) => p.set(show)).catch(() => { popup = null })
    }
    if (next >= 0) timer = setTimeout(tick, Math.min(next, MAX_DELAY))
  }

  async function read() {
    if (!active) return
    const mine = ++seq
    lastRead = Date.now()
    const { from, to } = reminderWindow(lastRead)
    let body: unknown = null
    try { body = await fetchReminders(api, from, to) } catch { return /* keep the last list and its timer */ }
    if (mine !== seq || !active) return
    list = readReminders(body)
    tick()
  }

  const stale = () => Date.now() - lastRead >= REMINDER_FOCUS_GAP_MS
  window.addEventListener('focus', () => { if (stale()) void read() })
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && stale()) void read() })
  window.addEventListener(CALENDAR_CHANGED_EVENT, () => { void read() })
  setInterval(() => { void read() }, REMINDER_REFRESH_MS)

  return {
    start() {
      if (active) return
      active = true
      void read()
    },
    stop() {
      active = false
      seq++
      list = []
      tick()
    },
  }
}
