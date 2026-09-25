/**
 * Browser live client for the hub WUI socket (specs/003 contracts/wui-live-ws.md 0.1.0).
 *
 * The box socket /v1/ws (Ed25519 hello) is never used from the browser.
 *
 * Lifecycle: connect → hello (token / display name) → welcome → subscribe(task_id)*
 * → message / presence frames (live) ; send → ack | error. Reconnects with capped
 * backoff and re-subscribes, then signals `onReconnected` so the caller can catch
 * up with view-v1 `after=<last cursor>` (§7); sends made while disconnected wait
 * in a queue.
 */

import { copyEditFields } from './view-api.mjs'

export const FRAMES = {
  hello: 'hello',
  welcome: 'welcome',
  subscribe: 'subscribe',
  unsubscribe: 'unsubscribe',
  send: 'send',
  message: 'message',
  ack: 'ack',
  error: 'error',
  subscribed: 'subscribed',
  token: 'token',
  presence: 'presence',
  /* CLE-3425: a channel created anywhere in the tenant (wui-live-ws v0.6) */
  channel: 'channel',
  /*
   * CLE-3445 / message-edit-v1 §3: a message whose body was edited.
   *
   * It CANNOT be delivered as a second `message` frame, and that is measured
   * rather than assumed. `git show origin/master:src/utils/feed.mjs | sed -n
   * '77,95p'` -> `} else if (list[i].pending && !m.pending) {`: mergeById()
   * replaces a held row ONLY while the held row is pending, so a `message`
   * frame for a msg_id already held as confirmed is silently dropped — on
   * every screen that already had the message, which is every screen that
   * matters. Hence its own type and its own replace-by-msg_id handler.
   */
  edited: 'message_edited',
}

/** wui-live-ws §2: hello.as must be a v:1 agent id (e.g. HUM-2); anything else is omitted and the hub assigns a guest GST-<n> (0.4.1). */
export const AGENT_ID_RE = /^[A-Z]{2,4}-[0-9]+$/

export function cleanAs(s) {
  const v = String(s || '').trim().toUpperCase()
  return AGENT_ID_RE.test(v) ? v : ''
}

/** true when the upload token is missing or expires within `skewMs`. */
export function tokenStale(expiresAt, now = Date.now(), skewMs = 15000) {
  const t = Date.parse(String(expiresAt || ''))
  return !Number.isFinite(t) || t - now <= skewMs
}

export const WS_PATH = '/v1/wui/ws'

/** http(s)://host → ws(s)://host + path */
export function wsUrl(base, path = WS_PATH) {
  const b = String(base || '').replace(/\/+$/, '')
  if (!/^https?:\/\//.test(b)) throw new Error('ws base must be http(s)')
  return b.replace(/^http/, 'ws') + path
}

export function backoffMs(attempt, { base = 500, cap = 30000 } = {}) {
  return Math.min(cap, base * 2 ** Math.max(0, attempt))
}

function newId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID()
  return `${Date.now().toString(16)}-${Math.random().toString(16).slice(2)}`
}

/** channels-v1 §2: absent, null and "" all mean absent → null. */
function hubField(v) {
  return typeof v === 'string' && v ? v : null
}

/**
 * Normalise an incoming message frame to a flat v:1-ish object the cards render.
 * Accepts { env: { from_box, to_box, channel?, parent_task_id?, msg } } (view-v1
 * §4.4 shape) or { msg } or a flat message. The hub-envelope `channel` /
 * `parent_task_id` land on the flat object (null when absent).
 */
export function messageFromFrame(f) {
  const x = f || {}
  const env = x.env && typeof x.env === 'object' ? x.env : null
  const inner = env ? env.msg : (x.msg && typeof x.msg === 'object' ? x.msg : x)
  const out = { ...(inner || {}) }
  delete out.type
  delete out.sig
  if (env) {
    out.from_box = env.from_box
    out.to_box = env.to_box
    out.channel = hubField(x.channel) || hubField(env.channel)
    out.parent_task_id = hubField(env.parent_task_id)
  }
  if (x.cursor !== undefined) out.cursor = x.cursor
  if (x.received_at !== undefined) out.received_at = x.received_at
  if (x.is_parent === 0 || x.is_parent === 1) out.is_parent = x.is_parent
  /* message-edit-v1 §6: edited_at / edited_by / revision sit on the FRAME,
     beside cursor, not inside env.msg — same allow-list gap as view-api's */
  copyEditFields(x, out)
  return out
}

export function createLiveClient({
  url,
  token = '',
  as = '',
  WebSocketImpl = globalThis.WebSocket,
  onMessage = () => {},
  onState = () => {},
  onWelcome = () => {},
  onToken = () => {},
  onPresence = () => {},
  /** CLE-3425 §3.3 `channel` frames ({ channel, name, created_by, created_at }). */
  onChannel = () => {},
  /** CLE-3445: a `message_edited` frame — a REPLACEMENT for a row already held. */
  onEdited = () => {},
  onReconnected = () => {},
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = (t) => clearTimeout(t),
  ackTimeoutMs = 10000,
} = {}) {
  let ws = null
  let state = 'idle'
  let attempt = 0
  let closedByUs = false
  let retryTimer = null
  let welcome = null
  let dropped = false
  const cursors = new Map()
  const subs = new Set()
  const chanSubs = new Set()
  const peerSubs = new Set()
  /* CLE-3425: `all` is ref-counted. The topic list holds it while `/` is open
     and the app shell holds it for the whole tab, so the page leaving `/` must
     not take the shell's follow down with it. */
  let allSub = 0
  const queue = []
  const pending = new Map()
  const tokenWaiters = []

  function setState(s) {
    state = s
    onState(s)
  }

  function raw(obj) {
    ws.send(JSON.stringify(obj))
  }

  function flush() {
    while (queue.length && state === 'open') raw(queue.shift())
  }

  function connect() {
    if (typeof WebSocketImpl !== 'function') throw new Error('no WebSocket')
    closedByUs = false
    setState('connecting')
    ws = new WebSocketImpl(url)
    ws.onopen = () => {
      const hello = { type: FRAMES.hello }
      if (token) hello.token = token
      const id = cleanAs(as)
      if (id) hello.as = id
      raw(hello)
    }
    ws.onmessage = (ev) => {
      let f
      try {
        f = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data))
      } catch {
        return
      }
      handle(f)
    }
    ws.onclose = () => {
      ws = null
      for (const [, p] of pending) {
        clearTimer(p.timer)
        p.reject(Object.assign(new Error('socket closed'), { token: 'closed' }))
      }
      pending.clear()
      if (closedByUs) {
        setState('closed')
        return
      }
      dropped = true
      setState('reconnecting')
      retryTimer = setTimer(connect, backoffMs(attempt++))
    }
    ws.onerror = () => {
      /* onclose follows */
    }
  }

  function handle(f) {
    switch (f.type) {
      case FRAMES.welcome:
        welcome = f
        attempt = 0
        setState('open')
        for (const id of subs) raw({ type: FRAMES.subscribe, task_id: id })
        for (const ch of chanSubs) raw({ type: FRAMES.subscribe, channel: ch })
        for (const p of peerSubs) raw({ type: FRAMES.subscribe, peer: p })
        if (allSub > 0) raw({ type: FRAMES.subscribe, all: true })
        flush()
        onWelcome(f)
        if (dropped) {
          dropped = false
          onReconnected(f, { cursors: Object.fromEntries(cursors) })
        }
        return
      case FRAMES.presence:
        onPresence(f)
        return
      case FRAMES.channel:
        onChannel(f)
        return
      case FRAMES.token:
        onToken(f)
        while (tokenWaiters.length) tokenWaiters.shift()(f)
        return
      case FRAMES.message: {
        const m = messageFromFrame(f)
        const tid = f.task_id || m.task_id
        if (tid && m.cursor) cursors.set(String(tid), m.cursor)
        onMessage(m, f)
        return
      }
      case FRAMES.edited: {
        /* The same payload shape as `message` plus msg_id and the three edit
           fields. It is NOT fed to onMessage: an edit is a replacement, and
           the merge every onMessage listener runs appends or ignores.
           message-edit-v1 §FR-ED-009 also guarantees ts / received_at /
           cursor are UNCHANGED by an edit, so the cursor map is deliberately
           left alone here — a typo fix must not move the read position. */
        const m = messageFromFrame(f)
        if (f.msg_id && !m.msg_id) m.msg_id = f.msg_id
        onEdited(m, f)
        return
      }
      case FRAMES.ack: {
        const p = pending.get(f.msg_id)
        if (p) {
          clearTimer(p.timer)
          pending.delete(f.msg_id)
          p.resolve(f)
        }
        return
      }
      case FRAMES.error: {
        const p = f.msg_id ? pending.get(f.msg_id) : null
        const err = Object.assign(new Error(f.detail || f.error || 'error'), { token: f.error, status: f.status })
        if (p) {
          clearTimer(p.timer)
          pending.delete(f.msg_id)
          p.reject(err)
        }
        return
      }
      default:
    }
  }

  return {
    get state() {
      return state
    },
    get welcome() {
      return welcome
    },
    /** Last cursor seen per task_id (message frames): the `after=` of a catch-up. */
    lastCursor(taskId) {
      return cursors.get(String(taskId || '')) || ''
    },
    connect,
    close() {
      closedByUs = true
      if (retryTimer) clearTimer(retryTimer)
      if (ws) ws.close()
      else setState('closed')
    },
    subscribe(taskId) {
      const id = String(taskId || '')
      if (!id || subs.has(id)) return
      subs.add(id)
      if (state === 'open') raw({ type: FRAMES.subscribe, task_id: id })
    },
    unsubscribe(taskId) {
      const id = String(taskId || '')
      if (!subs.delete(id)) return
      if (state === 'open') raw({ type: FRAMES.unsubscribe, task_id: id })
    },
    /** wui-live-ws v0.4: every message stored in `channel`, new roots included. */
    subscribeChannel(channel) {
      const ch = String(channel || '').replace(/^#/, '').toLowerCase()
      if (!ch || chanSubs.has(ch)) return
      chanSubs.add(ch)
      if (state === 'open') raw({ type: FRAMES.subscribe, channel: ch })
    },
    unsubscribeChannel(channel) {
      const ch = String(channel || '').replace(/^#/, '').toLowerCase()
      if (!chanSubs.delete(ch)) return
      if (state === 'open') raw({ type: FRAMES.unsubscribe, channel: ch })
    },
    /** wui-live-ws v0.5: every DM with `peer` (<id> or <id>@<box>), new roots included. */
    subscribePeer(peer) {
      const p = String(peer || '')
      if (!p || peerSubs.has(p)) return
      peerSubs.add(p)
      if (state === 'open') raw({ type: FRAMES.subscribe, peer: p })
    },
    unsubscribePeer(peer) {
      const p = String(peer || '')
      if (!peerSubs.delete(p)) return
      if (state === 'open') raw({ type: FRAMES.unsubscribe, peer: p })
    },
    /** wui-live-ws v0.5: the whole tenant, for the topic list (DMs only when party). */
    subscribeAll() {
      allSub++
      if (allSub > 1) return
      if (state === 'open') raw({ type: FRAMES.subscribe, all: true })
    },
    unsubscribeAll() {
      if (allSub === 0) return
      allSub--
      if (allSub > 0) return
      if (state === 'open') raw({ type: FRAMES.unsubscribe, all: true })
    },
    /** wui-live-ws: {type:"token"} → next token frame (fresh upload token). */
    requestToken() {
      return new Promise((resolve) => {
        tokenWaiters.push(resolve)
        if (state === 'open') raw({ type: FRAMES.token })
        else queue.push({ type: FRAMES.token })
      })
    },
    /**
     * Resolves with the ack frame; rejects on error frame, timeout or close. kind is
     * a v:1 kind (default note); to defaults to ALL-0 hub-side. `channel` /
     * `parent_task_id` are hub-envelope fields (wui-live-ws §4), sent only when set;
     * a caller `msg_id` makes a resend idempotent.
     */
    send({ task_id, kind = 'note', body = '', files = [], to, channel, parent_task_id, is_parent, msg_id: givenId } = {}) {
      const msg_id = givenId ? String(givenId) : newId()
      const frame = { type: FRAMES.send, msg_id, task_id: String(task_id || ''), kind, body: String(body), files }
      if (to) frame.to = to
      if (channel) frame.channel = String(channel)
      if (parent_task_id) frame.parent_task_id = String(parent_task_id)
      if (is_parent === 0 || is_parent === 1) frame.is_parent = is_parent
      return new Promise((resolve, reject) => {
        const timer = setTimer(() => {
          pending.delete(msg_id)
          reject(Object.assign(new Error('send timed out'), { token: 'timeout' }))
        }, ackTimeoutMs)
        pending.set(msg_id, { resolve, reject, timer })
        if (state === 'open') raw(frame)
        else queue.push(frame)
      })
    },
  }
}
