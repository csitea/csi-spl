/**
 * 080 T006 (FR-009, mobile §3.3): send when the network is back.
 *
 * A member on a train writes, presses Enter, and the network is gone. Before
 * this, the send failed after the ack timeout, the row went away and the text
 * came back with a Retry - and Retry minted a NEW msg_id, so a first copy
 * that did reach the hub became a duplicate.
 *
 * Now a send that fails for network reasons keeps its pending row, marked
 * "waiting for network", and is held here under its msg_id. On reconnect (or
 * the browser's `online`) every held send is sent again with the SAME msg_id,
 * so the hub's de-dupe makes the replay safe. TopBar's Retry reuses the
 * msg_id of the send it repeats (retryWith / takeMsgId).
 */
import { failureToken } from './send-failure.mjs'

/** The browser says there is no network (navigator.onLine === false). */
export function isOffline(nav = globalThis.navigator) {
  return Boolean(nav) && nav.onLine === false
}

/**
 * A failure the network caused, not the hub: the socket closed or the ack
 * never came ('closed' / 'timeout') while the browser is offline or the
 * socket is not open. A timeout on an open socket while online is a slow hub:
 * that one is reported (Retry), not held.
 */
export function isNetworkFailure(err, { offline = false, socket = 'open' } = {}) {
  const t = failureToken(err)
  if (t !== 'closed' && t !== 'timeout') return false
  return Boolean(offline) || socket !== 'open'
}

/** What a send attempted while offline throws: a token like every other one. */
export function offlineError() {
  return Object.assign(new Error('offline'), { token: 'closed' })
}

/**
 * The held sends, by msg_id. `drain()` sends each again in the order held;
 * one that fails for network reasons (`stillOffline(err)`) stays, and the
 * drain stops there for the next reconnect. One that lands - or fails for
 * good - leaves; `onFail(msgId, err)` hears the second kind, so nothing is
 * dropped without a word.
 */
export function createSendQueue({ stillOffline = (err) => isNetworkFailure(err, { offline: isOffline() }), onFail = (_msgId, _err) => {} } = {}) {
  const held = new Map()
  let running = null

  async function runOnce() {
    for (const [msgId, resend] of [...held]) {
      try {
        await resend()
        held.delete(msgId)
      } catch (err) {
        if (stillOffline(err)) break
        held.delete(msgId)
        onFail(msgId, err)
      }
    }
  }

  return {
    hold(msgId, resend) {
      if (msgId) held.set(String(msgId), resend)
    },
    has(msgId) {
      return held.has(String(msgId || ''))
    },
    get size() {
      return held.size
    },
    /** One drain at a time: a call while one runs joins it. */
    drain() {
      if (!running) running = runOnce().finally(() => { running = null })
      return running
    },
  }
}

/* TopBar's Retry: the msg_id of the failed send, for the next send of the
   SAME text only - a different send must never inherit it, or the hub would
   de-dupe a new message into the old one. */
let reuse = null

/** Arm (msgId, text) for the next send; retryWith('') disarms. */
export function retryWith(msgId, text = '') {
  reuse = msgId ? { msgId: String(msgId), text: String(text) } : null
}

/** The armed msg_id when `text` is the retried text, else `fresh`. One use. */
export function takeMsgId(text, fresh) {
  const r = reuse
  reuse = null
  return r && r.text === String(text) ? r.msgId : fresh
}
