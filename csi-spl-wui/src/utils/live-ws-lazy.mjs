/**
 * SPL-6342: the hub socket's code (live-ws.mjs) is not in the entry chunk.
 * The first screen is drawn from view reads; the socket only follows what
 * arrives after them. useLive gets this client at once, the same shape as
 * live-ws's createLiveClient, and the socket code loads with its first use.
 *
 * Until it has loaded, every call is kept in order and replayed on the real
 * client, so the real client sees the same calls it would have seen at once.
 * Nothing can arrive before then (no socket is open), so the reads answer
 * what a new client answers: no welcome, no cursor. `state` follows the
 * calls that set it at once on a real client (connect, close), and onState
 * hears them, as it would.
 *
 * A load that fails while a connect is kept reads `reconnecting`, as a real
 * client reads after a dropped dial, and loads again on its own after the
 * same equal-jitter backoff (0.5 s doubling to 30 s): useLive starts
 * watchLive only once the module is there, so nothing else would ask again.
 * A call made meanwhile loads at once. After close() a failure stays closed.
 *
 * Only `lazyLiveClient` is exported: Nuxt auto-imports every utils/ export by
 * name. live-ws.mjs's names are read as members of the loaded module only: a
 * bare name here would make Nuxt add a static import of it.
 */

/** The calls a real client answers with a promise: they wait for the load. */
const ASYNC_CALLS = ['checkRevision', 'requestToken', 'redialForToken', 'send', 'request']

/** The calls kept and replayed in order. */
const SYNC_CALLS = [
  'connect', 'redial', 'wake', 'close',
  'subscribe', 'unsubscribe', 'subscribeChannel', 'unsubscribeChannel',
  'subscribePeer', 'unsubscribePeer', 'subscribeAll', 'unsubscribeAll',
]

/**
 * live-ws reconnectDelayMs's wait, here: live-ws-lazy.mjs imports nothing statically.
 * @param {number} attempt
 * @param {() => number} random
 */
function loadRetryMs(attempt, random) {
  const d = Math.min(30000, 500 * 2 ** attempt)
  return Math.round(d / 2 + random() * (d / 2))
}

/**
 * The timed retry of a failed load: one timer at a time, each wait longer.
 * @param {Record<string, any>} opts createLiveClient's options (setTimer, clearTimer, random)
 */
function loadRetry(opts) {
  const setTimer = opts?.setTimer || ((/** @type {() => void} */ fn, /** @type {number} */ ms) => setTimeout(fn, ms))
  const clearTimer = opts?.clearTimer || ((/** @type {any} */ t) => clearTimeout(t))
  const random = opts?.random || Math.random
  /** @type {any} */
  let timer = null
  let attempt = 0
  return {
    /** @param {() => void} fn */
    later(fn) {
      if (timer !== null) return
      timer = setTimer(() => {
        timer = null
        fn()
      }, loadRetryMs(attempt++, random))
    },
    stop() {
      if (timer !== null) clearTimer(timer)
      timer = null
      attempt = 0
    },
  }
}

/**
 * Run the kept calls in order on the real client.
 * @param {Array<[string, unknown[]]>} queue
 * @param {any} real
 */
function replay(queue, real) {
  while (queue.length) {
    const [name, args] = /** @type {[string, unknown[]]} */ (queue.shift())
    try {
      real[name](...args)
    } catch (err) {
      /* a real client would have thrown to its caller: surface it, go on with the rest */
      queueMicrotask(() => { throw err })
    }
  }
}

/**
 * @param {Record<string, any>} opts createLiveClient's options
 * @param {{ load?: () => Promise<any>, onLoad?: (mod: any, client: any) => void }} [hooks]
 *   load: the live-ws module (a test passes its own); onLoad: runs once, with the module and the real client
 */
export function lazyLiveClient(opts, { load = () => import('./live-ws.mjs'), onLoad } = {}) {
  /** @type {any} */
  let real = null
  /** @type {Promise<any> | null} */
  let loading = null
  /** @type {Array<[string, unknown[]]>} */
  const queue = []
  let state = 'idle'
  const retry = loadRetry(opts)

  function ready() {
    return (loading ||= load().then((mod) => {
      retry.stop()
      real = mod.createLiveClient(opts)
      replay(queue, real)
      if (onLoad) onLoad(mod, real)
      return real
    }, (err) => {
      /* the next call, or the timed retry, loads again; the kept calls wait for it */
      loading = null
      retryLater()
      throw err
    }))
  }

  /** A kept connect that cannot load yet reads reconnecting and is tried again, as a real client redials. */
  function retryLater() {
    if (real || (state !== 'connecting' && state !== 'reconnecting')) return
    if (state !== 'reconnecting') setState('reconnecting')
    retry.later(() => {
      if (!real && state === 'reconnecting') ready().catch(() => {}) // ready() handled it: reconnecting, the next retry set
    })
  }

  /** @type {Record<string, any>} */
  const api = {
    get state() {
      return real ? real.state : state
    },
    get welcome() {
      return real ? real.welcome : null
    },
    /** @param {string} taskId */
    lastCursor(taskId) {
      return real ? real.lastCursor(taskId) : ''
    },
  }
  for (const name of SYNC_CALLS) {
    api[name] = (/** @type {unknown[]} */ ...args) => {
      if (real) return real[name](...args)
      queue.push([name, args])
      if (name === 'connect' && state !== 'connecting') setState('connecting')
      if (name === 'close') {
        retry.stop()
        if (state !== 'closed') setState('closed')
      }
      ready().catch(() => {}) // ready() handled it: reconnecting and a timed retry while a connect is kept
    }
  }
  for (const name of ASYNC_CALLS) {
    api[name] = async (/** @type {unknown[]} */ ...args) => (real || await ready())[name](...args)
  }

  /** @param {string} s */
  function setState(s) {
    state = s
    if (opts && typeof opts.onState === 'function') opts.onState(s)
  }

  return api
}
