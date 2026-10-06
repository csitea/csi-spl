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

import { normalizeId, PARTICIPANT_ID_SRC } from './agent-id.mjs'

import { copyEditFields } from './view-api.mjs'

import { perfMark } from './perf-mark.mjs'
import { noteLastData } from './last-data.mjs'

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
  /* a channel created anywhere in the tenant (wui-live-ws v0.6) */
  channel: 'channel',
  /* SPL-72: a channel its creator deleted; sent to its members only */
  channelDeleted: 'channel_deleted',
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
  /* A message was deleted. Not a `message` frame: mergeById would keep the row. */
  deleted: 'message_deleted',
  /* one message folded into its neighbor — the kept row's edit
     plus `merged_from`, the row that is gone. Handled as the two frames it
     replaces, so every store that applies an edit or a delete applies it. */
  merged: 'message_merged',
  /* SPL-983 (specs/041 §3.4): a topic card archived / unarchived, or deleted with its children. */
  topicArchived: 'topic_archived',
  topicDeleted: 'topic_deleted',
  /* SPL-1024 (specs/045 move-v1 §6): a topic moved to another channel, a reply to another topic. */
  topicMoved: 'topic_moved',
  messageMoved: 'message_moved',
  /* 714c7028: a whole topic folded into another topic, and its undo. */
  topicMerged: 'topic_merged',
  topicUnmerged: 'topic_unmerged',
  /* An emoji was added or removed. Not a `message` frame: mergeById would keep the old row. */
  reaction: 'message_reaction',
  /* issues-v1 §5: pushed to every browser of the tenant. Not a message frame. */
  issue: 'issue',
  issue_label: 'issue_label',
  /* spec 062 §3.2: the viewer's Flow counts (+ the new event), to that member's sockets only */
  flow: 'flow',
}

/**
 * Spec 066 M8 reconnect_live: timed only after the tab was away (hidden, or
 * offline) longer than this, and only when a reconnect follows the wake
 * within RECONNECT_TIMED_MS.
 */
export const RECONNECT_AWAY_MS = 30_000
export const RECONNECT_TIMED_MS = 120_000

/** M8's `hidden_s` bucket for an away time in ms (spec 4.1). */
export function awayBucket(ms) {
  if (ms >= 3_600_000) return '3600+'
  return ms >= 300_000 ? '300-3600' : '30-300'
}

const perfNow = () => (globalThis.performance ? globalThis.performance.now() : Date.now())

/** wui-live-ws §2: hello.as must be a v:1 agent id (e.g. HUM-2, c-004); anything else is omitted and the hub assigns a guest GST-<n> (0.4.1). */
export const AGENT_ID_RE = new RegExp(`^${PARTICIPANT_ID_SRC}$`)

export function cleanAs(s) {
  return normalizeId(s)
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

/**
 * The wait before reconnect `attempt`: "equal jitter", half of backoffMs fixed
 * and half random (the box client's hubclient/flush.go rule). Every hub deploy
 * drops every browser socket at the same instant; without jitter they all
 * redialled the new revision in the same 500 ms, then the same 1 s, and so on.
 */
export function reconnectDelayMs(attempt, random = Math.random) {
  const d = backoffMs(attempt)
  return Math.round(d / 2 + random() * (d / 2))
}

/** Consecutive refused dials (closed before `open`) after which the session is probed. */
export const REFUSED_PROBE_AFTER = 2

function newId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID()
  return `${Date.now().toString(16)}-${Math.random().toString(16).slice(2)}`
}

/** channels-v1 §2: absent, null and "" all mean absent → null. */
function hubField(v) {
  return typeof v === 'string' && v ? v : null
}

/** The hub's view cursor for a row: base64url of `<received_at>|<msg_id>` (hub encCursor). */
export function frameCursor(receivedAt, msgId) {
  if (typeof receivedAt !== 'string' || !receivedAt || typeof msgId !== 'string' || !msgId) return undefined
  let bin = ''
  for (const b of new TextEncoder().encode(`${receivedAt}|${msgId}`)) bin += String.fromCharCode(b)
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/** The box a trimmed `message` frame (R2-3) leaves out: the browser's own. */
const WUI_BOX = 'box-wui'

/**
 * Normalise an incoming message frame to a flat v:1-ish object the cards render.
 * Accepts { env: { from_box, to_box, channel?, parent_task_id?, msg } } (view-v1
 * §4.4 shape) or { msg } or a flat message. The hub-envelope `channel` /
 * `parent_task_id` land on the flat object (null when absent).
 *
 * db-payload audit round 2, R2-3: the hub's `message` frame leaves out what it
 * already says once or what is a default - `cursor`, env.channel (= the
 * frame's channel), env.msg.task_id (= the frame's task_id), env.msg.files
 * `[]`, env.sig "" and box-wui ends. Each is put back here, so the object is
 * the one the full frame gave; a full frame (older hub, edits, merges) reads
 * as before.
 */
export function messageFromFrame(f) {
  const x = f || {}
  const env = x.env && typeof x.env === 'object' ? x.env : null
  const inner = env ? env.msg : (x.msg && typeof x.msg === 'object' ? x.msg : x)
  const out = { ...(inner || {}) }
  delete out.type
  delete out.sig
  if (env) {
    out.from_box = 'from_box' in env ? env.from_box : WUI_BOX
    out.to_box = 'to_box' in env ? env.to_box : WUI_BOX
    out.channel = hubField(x.channel) || hubField(env.channel)
    out.parent_task_id = hubField(env.parent_task_id)
    /* env.msg.task_id: the frame's task_id lands on out in copyMoveFields */
    if (x.type === FRAMES.message && inner && typeof inner === 'object' && !('files' in inner)) out.files = []
  }
  if (x.cursor !== undefined) out.cursor = x.cursor
  else if (env && x.type === FRAMES.message) {
    const c = frameCursor(x.received_at, out.msg_id)
    if (c) out.cursor = c
  }
  if (x.received_at !== undefined) out.received_at = x.received_at
  if (x.is_parent === 0 || x.is_parent === 1) out.is_parent = x.is_parent
  /* message-edit-v1 §6: edited_at / edited_by / revision sit on the FRAME,
     beside cursor, not inside env.msg — same allow-list gap as view-api's */
  copyEditFields(x, out)
  /* specs/036 FR-011: the verified typist rides on the frame, like edited_by */
  if (typeof x.typed_by === 'string' && x.typed_by) out.typed_by = x.typed_by
  /* spec 068: the responsible seat rides on the frame too */
  if (typeof x.responsible === 'string' && x.responsible) out.responsible = x.responsible
  /* spec 067: ref_task_id / mirror_of ride on the frame like the view row */
  if (typeof x.ref_task_id === 'string' && x.ref_task_id) out.ref_task_id = x.ref_task_id
  if (typeof x.mirror_of === 'string' && x.mirror_of) out.mirror_of = x.mirror_of
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
  /** a `message_edited` frame — a REPLACEMENT for a row already held. */
  onEdited = () => {},
  /** `message_deleted`: drop the row. `{ msg_id, task_id }`. */
  onDeleted = () => {},
  /** SPL-983 `topic_archived` / `topic_deleted`, SPL-1024 `topic_moved` / `message_moved`: the whole frame. */
  onTopic = () => {},
  /** `message_reaction`: replace the emoji list on a row already held. */
  onReaction = () => {},
  /** issues-v1 §5 `{type:"issue", op, issue}`. */
  onIssue = () => {},
  /** issues-v1 §5 `{type:"issue_label", label}`. */
  onIssueLabel = () => {},
  onFlow = () => {},
  onReconnected = () => {},
  /**
   * Resolves true only when the human is signed OUT (auth-v1 §4 session 401).
   * The hub refuses the upgrade of a tab whose session ended with a 401 the
   * browser never sees (the socket just closes before `open`), so without this
   * such a tab redialled every 31 s for as long as it stayed open: 265 refused
   * upgrades in 2 h 15 min from one tab on prd, 2026-09-28. A signed-out
   * answer parks the client in state `signed_out`; connect() resumes it.
   */
  isSignedOut = async () => false,
  /**
   * Bug B (4ecb4b0d): resolves the hub revision serving NEW requests now
   * (GET /v1/wui/revision), '' when unknown. See checkRevision.
   */
  fetchRevision = async () => '',
  random = Math.random,
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = (t) => clearTimeout(t),
  ackTimeoutMs = 10000,
  /** wake(): an open socket that answers nothing within this is re-dialled. */
  probeTimeoutMs = 5000,
  /** M8's clock (performance.now in the browser). */
  now = perfNow,
} = {}) {
  let ws = null
  let state = 'idle'
  let attempt = 0
  let refused = 0
  let closedByUs = false
  let retryTimer = null
  let welcome = null
  let dropped = false
  /* bumped by every frame the hub sends: wake() reads it to tell a live
     socket from a half-open one */
  let frames = 0
  /* M8: armed by a wake after a long away, timed by the reconnect that follows */
  let woke = null
  const cursors = new Map()
  const subs = new Set()
  const chanSubs = new Set()
  const peerSubs = new Set()
  /* `all` is ref-counted. The topic list holds it while `/` is open
     and the app shell holds it for the whole tab, so the page leaving `/` must
     not take the shell's follow down with it. */
  let allSub = 0
  const queue = []
  const pending = new Map()
  /* Each waiter is { resolve, reject, timer }: a fresh upload token is asked
     for over the socket (requestToken) or by redialling onto the live revision
     (redialForToken, CLE-77795); both time out rather than hang a stuck tab. */
  const tokenWaiters = []

  function setState(s) {
    state = s
    onState(s)
  }

  /** M8 end: the socket is live again and the catch-up was handed its cursors. */
  function timedReconnect() {
    const w = woke
    woke = null
    const ms = w ? now() - w.t0 : -1
    if (w && ms <= RECONNECT_TIMED_MS) perfMark('reconnect_live', ms, { hiddenS: w.hiddenS })
  }

  /** A welcome or a token frame carries a fresh upload token: hand it to every waiter. */
  function resolveTokens(f) {
    while (tokenWaiters.length) {
      const w = tokenWaiters.shift()
      clearTimer(w.timer)
      w.resolve(f)
    }
  }

  /** The session is gone (signed out): fail the waiters so the caller can say so. */
  function rejectTokens(err) {
    while (tokenWaiters.length) {
      const w = tokenWaiters.shift()
      clearTimer(w.timer)
      w.reject(err)
    }
  }

  /** Queue a token waiter that `kick` prods, and that rejects after ackTimeoutMs. */
  function awaitToken(kick) {
    return new Promise((resolve, reject) => {
      const w = { resolve, reject, timer: null }
      w.timer = setTimer(() => {
        const i = tokenWaiters.indexOf(w)
        if (i >= 0) tokenWaiters.splice(i, 1)
        reject(Object.assign(new Error('token refresh timed out'), { token: 'timeout' }))
      }, ackTimeoutMs)
      tokenWaiters.push(w)
      kick()
    })
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
    if (state === 'signed_out') refused = 0
    if (retryTimer) clearTimer(retryTimer)
    retryTimer = null
    setState('connecting')
    let opened = false
    ws = new WebSocketImpl(url)
    ws.onopen = () => {
      opened = true
      refused = 0
      const hello = { type: FRAMES.hello }
      if (token) hello.token = token
      const id = cleanAs(as)
      if (id) hello.as = id
      raw(hello)
    }
    ws.onmessage = (ev) => {
      frames++
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
      rejectPending()
      if (closedByUs) {
        setState('closed')
        return
      }
      dropped = true
      setState('reconnecting')
      if (!opened && ++refused >= REFUSED_PROBE_AFTER) {
        probeThenRetry()
        return
      }
      retry()
    }
    ws.onerror = () => {
      /* onclose follows */
    }
  }

  /* every send still waiting for its ack fails 'closed' (one resend follows) */
  function rejectPending() {
    for (const [, p] of pending) {
      clearTimer(p.timer)
      p.reject(Object.assign(new Error('socket closed'), { token: 'closed' }))
    }
    pending.clear()
  }

  /**
   * Bug B: drop this socket NOW and dial again, without waiting for a close
   * the browser may take minutes to report. The old socket's handlers are
   * detached first so its late onclose cannot schedule a second dial. The
   * welcome on the new socket fires onReconnected - the catch-up read that
   * fetches whatever the old socket never pushed.
   */
  function redial() {
    if (closedByUs || !ws) return
    const old = ws
    ws = null
    old.onopen = old.onmessage = old.onclose = old.onerror = null
    try { old.close() } catch { /* already closing */ }
    rejectPending()
    dropped = true
    connect()
  }

  function retry() {
    retryTimer = setTimer(connect, reconnectDelayMs(attempt++, random))
  }

  /* Refused dials: ask whether the session ended before dialling again. Any
     answer other than a definite "signed out" (an error included) keeps the
     usual backoff, so a hub outage never parks a signed-in tab. */
  function probeThenRetry() {
    Promise.resolve()
      .then(() => isSignedOut())
      .catch(() => false)
      .then((out) => {
        if (closedByUs || state !== 'reconnecting') return
        if (out === true) {
          setState('signed_out')
          /* an upload waiting for a fresh token will never get one now */
          rejectTokens(Object.assign(new Error('signed out'), { token: 'signed_out' }))
          return
        }
        retry()
      })
  }

  function handle(f) {
    // A frame the hub delivered. An error frame is a refusal, not data.
    // typeof null === 'object', so a null frame must return before f.type.
    if (!f || typeof f !== 'object') return
    if (f.type !== FRAMES.error) noteLastData()
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
        /* the welcome carries a fresh upload token minted on THIS (live)
           revision — resolve any redial/token waiter with it (CLE-77795). */
        resolveTokens(f)
        if (dropped) {
          dropped = false
          /* M8 ends when the catch-up is done: awaited when the caller returns its promise */
          const caught = onReconnected(f, { cursors: Object.fromEntries(cursors) })
          if (woke) Promise.resolve(caught).then(timedReconnect, timedReconnect)
        }
        return
      case FRAMES.presence:
        onPresence(f)
        return
      case FRAMES.channel:
      case FRAMES.channelDeleted:
        onChannel(f)
        return
      case FRAMES.token:
        onToken(f)
        resolveTokens(f)
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
      case FRAMES.deleted: {
        onDeleted({ msg_id: f.msg_id, task_id: f.task_id }, f)
        return
      }
      case FRAMES.merged: {
        const m = messageFromFrame(f)
        if (f.msg_id && !m.msg_id) m.msg_id = f.msg_id
        onEdited(m, f)
        if (f.merged_from) onDeleted({ msg_id: f.merged_from, task_id: f.task_id }, f)
        return
      }
      case FRAMES.topicArchived:
      case FRAMES.topicDeleted:
      case FRAMES.topicMoved:
      case FRAMES.messageMoved:
      case FRAMES.topicMerged:
      case FRAMES.topicUnmerged:
        onTopic(f)
        return
      case FRAMES.reaction: {
        onReaction({
          msg_id: f.msg_id,
          task_id: f.task_id,
          reactions: Array.isArray(f.reactions) ? f.reactions : [],
        }, f)
        return
      }
      case FRAMES.issue:
        onIssue(f)
        return
      case FRAMES.issue_label:
        onIssueLabel(f)
        return
      case FRAMES.flow:
        onFlow(f)
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
    /** Last cursor seen per task_id (message frames): the `after=` of a catch-up. */
    lastCursor(taskId) {
      return cursors.get(String(taskId || '')) || ''
    },
    connect,
    redial,
    /**
     * Bug B (t1 #spool-hub-bugs 4ecb4b0d): a hub deploy leaves this socket on
     * the old Cloud Run revision for up to an hour, still ponging, while every
     * post stored by the new revision is pushed only to the sockets IT holds.
     * The reader saw those posts minutes late, at the next drop. So ask which
     * revision serves new requests and, when it is not the one this socket's
     * welcome named, re-dial onto it. Resolves true when it re-dialled.
     */
    async checkRevision() {
      const mine = welcome && typeof welcome.revision === 'string' ? welcome.revision : ''
      if (state !== 'open' || !mine) return false
      let live = ''
      try { live = String((await fetchRevision()) || '') } catch { live = '' }
      if (!live || live === mine || state !== 'open' || welcome.revision !== mine) return false
      redial()
      return true
    },
    /**
     * The tab came back (visible / online): a phone that slept, or a laptop
     * that changed networks, can hold a socket that reads 'open' and is dead.
     * A parked retry dials now; an open socket must answer a token frame
     * within probeTimeoutMs or it is re-dialled. `awayMs` (how long the tab
     * was hidden or offline) arms M8 when it is over RECONNECT_AWAY_MS.
     */
    wake(awayMs = 0) {
      if (closedByUs) return
      if (awayMs > RECONNECT_AWAY_MS) woke = { t0: now(), hiddenS: awayBucket(awayMs) }
      if (state === 'reconnecting' && retryTimer) {
        connect()
        return
      }
      if (state !== 'open' || !ws) return
      const sock = ws
      const seen = frames
      raw({ type: FRAMES.token })
      setTimer(() => {
        if (ws === sock && frames === seen && state === 'open') redial()
        /* it answered: the socket was live all along, nothing to time */
        else if (ws === sock) woke = null
      }, probeTimeoutMs)
    },
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
      return awaitToken(() => {
        if (state === 'open') raw({ type: FRAMES.token })
        else queue.push({ type: FRAMES.token })
      })
    },
    /**
     * CLE-77795: POST /v1/files answered 401 'door' — the process serving REST
     * does not know our upload token. A hub redeploy (or a Cloud Run recycle)
     * leaves this socket on the drained revision, which keeps ponging, so the
     * token looks fresh to us yet the LIVE revision that now answers REST never
     * minted it. Drop the socket so the reconnect lands on the live revision and
     * resolve with its welcome upload token — the browser twin of the box
     * client's session probe (redeploy_test.go). Signed out → the waiter rejects.
     */
    redialForToken() {
      return awaitToken(() => {
        queue.push({ type: FRAMES.token })
        if (ws && (state === 'open' || state === 'connecting')) {
          try { ws.close() } catch { /* onclose drives the reconnect */ }
        } else if (state !== 'reconnecting') {
          connect()
        }
      })
    },
    /**
     * Resolves with the ack frame; rejects on error frame, timeout or close. kind is
     * a v:1 kind (default note); to defaults to ALL-0 hub-side. `channel` /
     * `parent_task_id` are hub-envelope fields (wui-live-ws §4), sent only when set;
     * a caller `msg_id` makes a resend idempotent. `to_box` (specs/058) pins
     * the box of `to`: CLE-001..003 run on every box, and a bare id announced
     * on two boxes is refused as ambiguous_to_box.
     */
    send({ task_id, kind = 'note', body = '', files = [], to, to_box, channel, parent_task_id, is_parent, msg_id: givenId } = {}) {
      const msg_id = givenId ? String(givenId) : newId()
      const frame = { type: FRAMES.send, msg_id, task_id: String(task_id || ''), kind, body: String(body), files }
      if (to) frame.to = to
      if (to && to_box) frame.to_box = String(to_box)
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

/** How often a tab asks which hub revision is live (bug B). */
export const REVISION_CHECK_MS = 15000

/**
 * Bug B: keep one tab's socket on the live hub revision and awake.
 * Every `everyMs` (a background tab is throttled by the browser to about once
 * a minute, and catches up at once when shown) and whenever the tab becomes
 * visible it checks the revision; on visible and on `online` it also wakes
 * the socket. Returns the function that stops watching.
 */
export function watchLive(client, {
  doc = globalThis.document,
  win = globalThis.window,
  everyMs = REVISION_CHECK_MS,
  setEvery = (fn, ms) => setInterval(fn, ms),
  clearEvery = (t) => clearInterval(t),
  now = perfNow,
} = {}) {
  const check = () => { void client.checkRevision() }
  /* M8: since when the tab was hidden or offline; wake() gets the away time */
  let awayAt = -1
  const away = () => { if (awayAt < 0) awayAt = now() }
  const back = () => {
    const ms = awayAt < 0 ? 0 : now() - awayAt
    awayAt = -1
    return ms
  }
  const onVisible = () => {
    if (doc && doc.visibilityState === 'hidden') { away(); return }
    client.wake(back())
    check()
  }
  const onOnline = () => client.wake(back())
  const timer = setEvery(check, everyMs)
  if (doc && doc.addEventListener) doc.addEventListener('visibilitychange', onVisible)
  if (win && win.addEventListener) {
    win.addEventListener('online', onOnline)
    win.addEventListener('offline', away)
  }
  return () => {
    clearEvery(timer)
    if (doc && doc.removeEventListener) doc.removeEventListener('visibilitychange', onVisible)
    if (win && win.removeEventListener) {
      win.removeEventListener('online', onOnline)
      win.removeEventListener('offline', away)
    }
  }
}
