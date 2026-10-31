// SPL-4513 R7 W1: a sign-out still closes the hub socket.
// The real useLive.ts is bundled with esbuild against stubs (the session
// store, the API and the live client), then driven the way the app drives
// it: a member opens the socket, the session turns 'out' (a hand sign-out,
// or the password change's signedOut()), and stopHubSocket(live), the
// sign-out close path of useSpoolEvents and lobby.vue, must close it.
// A settled visitor still gets no socket at all.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { stopHubSocket } from '../../src/utils/shell-bootstrap.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

const STUBS = {
  '~/utils/live-ws.mjs': `
    export const cleanAs = (s) => String(s || '')
    export const tokenStale = () => false
    export const watchLive = () => {}
    export const wsUrl = (b) => b
    export function createLiveClient(opts) {
      const client = {
        state: 'idle', connectCalls: 0, closeCalls: 0,
        connect() { this.connectCalls++; this.state = 'open'; opts.onState('open') },
        close() { this.closeCalls++; this.state = 'closed'; opts.onState('closed') },
      }
      globalThis.__liveTest.clients.push(client)
      return client
    }`,
  '~/composables/useSpoolApi': 'export const useSpoolApi = () => globalThis.__liveTest.api',
  '~/stores/session': 'export const useSessionStore = () => globalThis.__liveTest.session',
  '~/utils/auth-client-core.mjs': `
    export const authOrigin = (b) => b
    export const createAuthClient = () => ({ session: async () => ({ state: 'out' }) })`,
}

// the Nuxt auto-imports useLive.ts relies on
const BANNER = `
const ref = (value) => ({ value })
const computed = (fn) => ({ get value() { return fn() } })
const useRuntimeConfig = () => ({ public: { lobbyTaskId: '', authBase: '' } })
`

let bundled = ''
async function freshUseLive() {
  if (!bundled) {
    const out = await build({
      entryPoints: [join(WUI, 'src/composables/useLive.ts')],
      bundle: true,
      format: 'esm',
      platform: 'neutral',
      write: false,
      banner: { js: BANNER },
      define: { 'import.meta.client': 'true' },
      plugins: [{
        name: 'stubs',
        setup(b) {
          b.onResolve({ filter: /^~\// }, (a) => (STUBS[a.path]
            ? { path: a.path, namespace: 'stub' }
            : { path: join(WUI, 'src', a.path.slice(2)) + (/\.\w+$/.test(a.path) ? '' : '.ts') }))
          b.onLoad({ filter: /.*/, namespace: 'stub' }, (a) => ({ contents: STUBS[a.path], loader: 'js' }))
        },
      }],
    })
    bundled = out.outputFiles[0].text
  }
  // a new data: URL per call is a new module instance, with its own `live` singleton
  const url = `data:text/javascript;base64,${Buffer.from(`${bundled}\n// ${Math.random()}`).toString('base64')}`
  return (await import(url)).useLive
}

function harness(state) {
  globalThis.__liveTest = { clients: [], api: { mock: false, base: 'https://hub.example.com', token: '' }, session: { state } }
  return globalThis.__liveTest
}

describe('useLive: a sign-out closes the hub socket (SPL-4513 W1)', () => {
  it('a socket opened signed in is closed by stopHubSocket once the session is out', async () => {
    const t = harness('in')
    const live = (await freshUseLive())()
    const client = live.ensure()
    assert.ok(client, 'a member gets a socket')
    assert.equal(client.connectCalls, 1)
    t.session.state = 'out'
    stopHubSocket(live)
    assert.equal(client.closeCalls, 1, 'the sign-out closes the member socket')
    assert.equal(client.state, 'closed')
    assert.equal(client.connectCalls, 1, 'and never re-dials it')
    assert.equal(t.clients.length, 1, 'no second client is made')
  })

  it('ensure() while out hands back the open client without re-dialling it', async () => {
    const t = harness('in')
    const live = (await freshUseLive())()
    const client = live.ensure()
    t.session.state = 'out'
    client.state = 'signed_out'
    assert.equal(live.ensure(), client)
    assert.equal(client.connectCalls, 1, 'a parked client is not re-dialled while out')
  })

  it('a settled visitor gets no socket: null, no client, state signed_out', async () => {
    const t = harness('out')
    const live = (await freshUseLive())()
    assert.equal(live.ensure(), null)
    assert.equal(t.clients.length, 0)
    assert.equal(live.state.value, 'signed_out')
    stopHubSocket(live)
    assert.equal(t.clients.length, 0, 'the close path makes no client either')
  })
})
