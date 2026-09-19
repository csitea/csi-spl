/**
 * Browser live client for the hub WUI socket (specs/003 contracts/wui-live-ws.md 0.1.0).
 *
 * The box socket /v1/ws (Ed25519 hello) is never used from the browser.
 *
 * Lifecycle: connect → hello (token / display name) → welcome → subscribe(task_id)*
 * → message frames (live) ; send → ack | error. Reconnects with capped backoff and
 * re-subscribes; sends made while disconnected wait in a queue.
 */

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
}

/** wui-live-ws §2: hello.as must be a v:1 agent id (e.g. HUM-2); anything else is omitted and the hub assigns HUM-<n>. */
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

/**
 * Normalise an incoming message frame to a flat v:1-ish object the cards render.
 * Accepts { env: { from_box, to_box, msg } } (view-v1 §4.4 shape) or { msg } or a
 * flat message.
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
  }
  if (x.cursor !== undefined) out.cursor = x.cursor
  if (x.received_at !== undefined) out.received_at = x.received_at
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
  const subs = new Set()
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
        flush()
        onWelcome(f)
        return
      case FRAMES.token:
        onToken(f)
        while (tokenWaiters.length) tokenWaiters.shift()(f)
        return
      case FRAMES.message:
        onMessage(messageFromFrame(f), f)
        return
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
    /** wui-live-ws: {type:"token"} → next token frame (fresh upload token). */
    requestToken() {
      return new Promise((resolve) => {
        tokenWaiters.push(resolve)
        if (state === 'open') raw({ type: FRAMES.token })
        else queue.push({ type: FRAMES.token })
      })
    },
    /** Resolves with the ack frame; rejects on error frame, timeout or close. kind is a v:1 kind (default note); to defaults to ALL-0 hub-side. */
    send({ task_id, kind = 'note', body = '', files = [], to } = {}) {
      const msg_id = newId()
      const frame = { type: FRAMES.send, msg_id, task_id: String(task_id || ''), kind, body: String(body), files }
      if (to) frame.to = to
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
