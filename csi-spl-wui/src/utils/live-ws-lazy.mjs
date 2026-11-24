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
 * Only `lazyLiveClient` is exported: Nuxt auto-imports every utils/ export by
 * name. live-ws.mjs's names are read as members of the loaded module only: a
 * bare name here would make Nuxt add a static import of it.
 */

/** The calls a real client answers with a promise: they wait for the load. */
const ASYNC_CALLS = ['checkRevision', 'requestToken', 'redialForToken', 'send']

/** The calls kept and replayed in order. */
const SYNC_CALLS = [
  'connect', 'redial', 'wake', 'close',
  'subscribe', 'unsubscribe', 'subscribeChannel', 'unsubscribeChannel',
  'subscribePeer', 'unsubscribePeer', 'subscribeAll', 'unsubscribeAll',
]

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

  function replay() {
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

  function ready() {
    return (loading ||= load().then((mod) => {
      real = mod.createLiveClient(opts)
      replay()
      if (onLoad) onLoad(mod, real)
      return real
    }, (err) => {
      /* the next call tries again; the kept calls wait for it */
      loading = null
      throw err
    }))
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
      if (name === 'close' && state !== 'closed') setState('closed')
      ready().catch(() => {}) // a failed load is retried by the next call; the kept calls wait for it
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
