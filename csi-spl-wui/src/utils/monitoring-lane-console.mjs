// Spec 153 section 3.20 (SPL-4810; owner HUM-10, t1 27162335, msgs 038fa412,
// 8dd53bd9 and 3b2ba6f3): a lane's live console. The Lanes table opens a lane
// in a dialog; its Console button shows that lane's tmux screen, refreshed
// while the dialog stays open, and Save writes the shown lines to a local
// .txt. The hub's routes (internal/hub/lane_console.go): the operator door
// POST/GET /v1/operator/lane-console, the workspace door POST/GET
// /v1/lanes/console. A POST is the watch (the box captures only while one is
// on, 60 s), re-sent every CONSOLE_WATCH_MS; a GET reads the last capture,
// every CONSOLE_POLL_MS while the browser tab is visible. The screen is
// masked on the box before it leaves it; the page shows and saves it as is.
// Loaded only by the lane dialog and the client's laneConsole.
import { mockMeGet, mockRefused } from './act-as-mock.mjs'
import { LANES_MOCK_OPERATOR_KEY } from './monitoring-lanes.mjs'
import { isoSeconds } from './iso-seconds.mjs'

/** How often the open feed reads the last capture. */
export const CONSOLE_POLL_MS = 2000

/** How often the open feed renews its watch (the hub keeps one 60 s). */
export const CONSOLE_WATCH_MS = 20000

/** The routes: the workspace door (`own`) or the operator's. */
export function laneConsolePath(own) {
  return own ? '/v1/lanes/console' : '/v1/operator/lane-console'
}

/** The GET's query: the agent and its box ('' on the workspace door for an operator lane). */
export function laneConsoleQuery(agentId, agentBox) {
  return '?' + new URLSearchParams({ agent_id: agentId, agent_box: agentBox || '' }).toString()
}

/**
 * The hub's answer as the dialog shows it: state waiting (no capture yet),
 * live or stale (the last capture is over 15 s old); the redaction count is
 * the sum over every kind.
 * @param {any} b
 */
export function laneConsoleOf(b) {
  const o = b && typeof b === 'object' ? b : {}
  const red = o.redactions && typeof o.redactions === 'object' ? Object.values(o.redactions) : []
  return {
    state: ['live', 'stale'].includes(o.state) ? String(o.state) : 'waiting',
    screen: typeof o.screen === 'string' ? o.screen : '',
    lines: Number.isFinite(o.lines) ? Number(o.lines) : 0,
    redacted: red.reduce((n, v) => n + (Number.isFinite(v) ? Number(v) : 0), 0),
    capturedAt: typeof o.captured_at === 'string' ? o.captured_at : '',
    ageS: Number.isFinite(o.age_s) ? Number(o.age_s) : 0,
  }
}

/**
 * The saved file's name: <agent>@<box>-<UTC yyyymmddThhmmssZ>.txt, the box
 * left out when the reader was not given it. Only [A-Za-z0-9._@-] survive.
 * @param {string} agentId
 * @param {string} agentBox
 * @param {Date} [now]
 */
export function laneConsoleFileName(agentId, agentBox, now = new Date()) {
  const at = isoSeconds(now).replace(/[-:]/g, '')
  const who = (agentId + (agentBox ? '@' + agentBox : '')).replace(/[^A-Za-z0-9._@-]/g, '_')
  return `${who}-${at}.txt`
}

/** The saved file's text: exactly the shown lines, one newline at the end. */
export function laneConsoleFileText(screen) {
  return screen ? screen.replace(/\n*$/, '\n') : ''
}

/**
 * Saves the shown lines as a local .txt (a Blob link, nothing sent).
 * @param {string} name
 * @param {string} text
 */
export function laneConsoleSave(name, text) {
  const url = URL.createObjectURL(new Blob([text], { type: 'text/plain;charset=utf-8' }))
  const a = document.createElement('a')
  a.href = url
  a.download = name
  a.rel = 'noopener'
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

/* ---- the mock bundle: the e2e opts into a door the way the Lanes tab does */

function mockStore() {
  try { return typeof localStorage === 'undefined' ? null : localStorage } catch { return null }
}

/** The mock's watched lanes, so a GET before a POST reads "waiting". */
const mockWatched = new Set()

/**
 * The mock's answer: the operator door for the mock operator admin, the
 * workspace door for a mock owner or admin, else the hub's 403. A watch
 * marks the lane; the first read after it is the capture.
 * @param {{ own: boolean, watch: boolean, agentId: string, agentBox: string }} q
 */
export function mockLaneConsole(q, store = mockStore(), now = new Date()) {
  const path = laneConsolePath(q.own)
  const allowed = q.own
    ? ['admin', 'biz_owner'].includes(String(mockMeGet(store ?? undefined)?.role || ''))
    : (() => { try { return store?.getItem(LANES_MOCK_OPERATOR_KEY) === '1' } catch { return false } })()
  if (!allowed) {
    throw mockRefused(path, Object.assign(new Error('only an admin sees a lane\'s console'), { status: 403, token: 'forbidden', permission: 'workspace.lanes' }))
  }
  const key = q.agentId + '@' + (q.agentBox || '')
  const base = { agent_id: q.agentId, agent_box: q.agentBox || '', redactions: {}, demand_until: '' }
  if (q.watch && !mockWatched.has(key)) {
    mockWatched.add(key)
    return { ...base, state: 'waiting', screen: '', lines: 0, captured_at: '', age_s: 0 }
  }
  const at = isoSeconds(now)
  const screen = [
    `${q.agentId} $ make test`,
    'go test ./internal/hub -run TestLaneConsole',
    'ok  github.com/csitea/csi-spl/spool-hub-api/internal/hub 0.52s',
    'export GH_TOKEN=<redacted:github-token>',
    `${q.agentId} $ `,
  ].join('\n')
  return { ...base, state: 'live', screen, lines: 5, redactions: { 'github-token': 1 }, captured_at: at, age_s: 1 }
}
