/**
 * Spec 107 T012: starts this tab's active-minute recorder (utils/hours-recorder.mjs)
 * once, from read-sync-boot's startReadSync, so it is a lazy chunk the feed
 * pages pull in, never the initial one (027). The open target is read from
 * the address at each counted minute; the switch is "Count my reading time"
 * (the hours_reading claim) and a signed-in member (the mock is always in).
 * The mock workspace's minutes go to localStorage (HOURS_MINUTES_MOCK_LOG).
 */
import { createHoursRecorder, hoursTargetOf, mockSendHoursMinutes } from '~/utils/hours-recorder.mjs'
import { hoursReadingOn } from '~/utils/hours-settings.mjs'
import { browserTimeZone } from '~/utils/date-iso.mjs'
import { useSessionStore } from '~/stores/session'

type Api = { mock: boolean, base: string, token: string, credentials: RequestCredentials }
type Batch = { tz: string, minutes: { at: string, target: string }[] }

let started = false

async function hubSend(api: Api, body: Batch, keepalive: boolean) {
  const headers: Record<string, string> = { accept: 'application/json', 'content-type': 'application/json' }
  if (api.token) headers.authorization = `Bearer ${api.token}`
  let res: Response
  try {
    res = await fetch(`${String(api.base).replace(/\/+$/, '')}/v1/me/hours/minutes`, {
      method: 'PUT', credentials: api.credentials, headers, body: JSON.stringify(body), keepalive,
    })
  } catch {
    throw Object.assign(new Error('network'), { status: 0 })
  }
  if (!res.ok) throw Object.assign(new Error(`hours minutes ${res.status}`), { status: res.status })
}

export function startHoursRecorder(api: Api) {
  if (started || !import.meta.client) return
  started = true
  const session = useSessionStore()
  createHoursRecorder({
    win: window,
    doc: document,
    target: () => hoursTargetOf(location.pathname, location.search),
    enabled: () => hoursReadingOn(session.claims?.hours_reading) && (api.mock || String(session.state) === 'in'),
    tz: () => session.claims?.time_zone || browserTimeZone() || 'UTC',
    send: (body: Batch, { keepalive }: { keepalive: boolean }) =>
      api.mock ? Promise.resolve(mockSendHoursMinutes(localStorage, body)) : hubSend(api, body, keepalive),
  })
}
