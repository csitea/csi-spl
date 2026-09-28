// (spec 027 perf P1): the WUI client's request waterfall.
//
// Measured on dev (build 947635e7, tests/e2e/perf-live.proof.mjs, n=1): one
// cold /lobby sent 7 view reads with no credentials before the door was known
// (7x 401, all retried), read /v1/view/roster six times, and downloaded the
// same attached picture 5-8 times per page. Each block below pins one fix and
// carries a control that fails on the old behaviour.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createSpoolClient, TOPIC_READS_IN_FLIGHT } from '../../src/utils/spool-client.mjs'
import { withSessionRetry } from '../../src/utils/live-follow.mjs'
import { sharedPreview, resetSharedPreviews, PREVIEW_CACHE_MAX } from '../../src/utils/file-preview.mjs'
import { loadAvatarFiles, resetAvatarFiles } from '../../src/utils/avatar.mjs'

const src = (p) => readFileSync(new URL(`../../${p}`, import.meta.url), 'utf8')
const tick = () => new Promise((r) => setTimeout(r, 0))

/** A fetch that holds every response until release(); counts calls per url. */
function heldFetch(body = { humans: [], boxes: [] }, status = 200) {
  const calls = []
  let open = null
  const gate = new Promise((r) => { open = r })
  const fn = async (url, opts = {}) => {
    calls.push({ url, opts })
    await gate
    return { ok: status < 300, status, headers: { get: () => 'application/json' }, json: async () => JSON.parse(JSON.stringify(body)) }
  }
  return { fn, calls, release: () => open() }
}

describe('identical GET reads in flight are one request (spool-client live)', () => {
  it('two concurrent roster reads -> one fetch, each caller its own copy', async () => {
    const f = heldFetch({ humans: [{ human_id: 'HUM-3' }], boxes: [] })
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: f.fn })
    const a = c.rosterView()
    const b = c.rosterView()
    await tick()
    f.release()
    const [x, y] = await Promise.all([a, b])
    assert.equal(f.calls.length, 1)
    assert.deepEqual(x, y)
    assert.notEqual(x, y, 'a joiner must not share the leader\'s object')
  })

  it('listRoster and rosterView join the same read', async () => {
    const f = heldFetch({ humans: [{ human_id: 'HUM-3' }], boxes: [] })
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: f.fn })
    const a = c.listRoster()
    const b = c.rosterView()
    await tick()
    f.release()
    await Promise.all([a, b])
    assert.equal(f.calls.length, 1)
  })

  it('control: reads that do not overlap each go out', async () => {
    const f = heldFetch()
    f.release()
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: f.fn })
    await c.rosterView()
    await c.rosterView()
    assert.equal(f.calls.length, 2)
  })

  it('a different door is a different read', async () => {
    const f = heldFetch()
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: f.fn })
    const a = c.rosterView()
    c.setDoor('session')
    const b = c.rosterView()
    await tick()
    f.release()
    await Promise.all([a, b])
    assert.equal(f.calls.length, 2)
    assert.deepEqual(f.calls.map((x) => x.opts.credentials), ['omit', 'include'])
  })

  it('writes are never joined', async () => {
    const f = heldFetch({})
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: f.fn })
    const a = c.removeTenantUser('HUM-9')
    const b = c.removeTenantUser('HUM-9')
    await tick()
    f.release()
    await Promise.all([a, b])
    assert.equal(f.calls.length, 2)
  })

  it('a failed shared read rejects every caller, and the next read goes out again', async () => {
    const f = heldFetch({ error: 'view_door' }, 401)
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: f.fn })
    const a = c.rosterView()
    const b = c.rosterView()
    await tick()
    f.release()
    await assert.rejects(a, (e) => e.status === 401)
    await assert.rejects(b, (e) => e.status === 401)
    assert.equal(f.calls.length, 1)
    await assert.rejects(c.rosterView())
    assert.equal(f.calls.length, 2)
  })

  it('per-topic reads go out TOPIC_READS_IN_FLIGHT at a time (HTTP/2 host)', async () => {
    assert.ok(TOPIC_READS_IN_FLIGHT >= 10)
    let now = 0
    let peak = 0
    const topics = Array.from({ length: 20 }, (_, i) => ({ task_id: `t${i}`, count: 1 }))
    const fn = async (url) => {
      const isList = url.includes('/v1/view/topics?')
      if (!isList) { now++; peak = Math.max(peak, now); await tick(); now-- }
      const body = isList ? { topics, next: null } : { messages: [{ msg_id: url, ts: '1', task_id: 'x' }], next: null }
      return { ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => body }
    }
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: fn })
    await c.listMessages({ channel: 'lobby' })
    assert.equal(peak, TOPIC_READS_IN_FLIGHT)
  })
})

describe('the session door is guessed from a signed-in probe (guessDoor)', () => {
  const door401 = () => Object.assign(new Error('spool 401 view_door'), { status: 401, token: 'view_door', detail: 'a view token or a member session is required' })

  it('a guessed session door sends credentials on the FIRST read: no 401 round', async () => {
    const f = heldFetch({ humans: [], boxes: [] })
    f.release()
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: f.fn })
    c.guessDoor('session')
    assert.equal(c.door, 'session')
    assert.equal(c.doorGuessed, true)
    await withSessionRetry(c, () => c.rosterView())
    assert.equal(f.calls.length, 1)
    assert.equal(f.calls[0].opts.credentials, 'include')
  })

  it('control: without the guess the same read costs a 401 and a retry', async () => {
    const calls = []
    const fn = async (url, opts) => {
      calls.push(opts.credentials)
      const ok = opts.credentials === 'include'
      const body = ok ? { humans: [], boxes: [] } : { error: 'view_door', detail: 'a view token or a member session is required' }
      return { ok, status: ok ? 200 : 401, headers: { get: () => 'application/json' }, json: async () => body }
    }
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: fn })
    await withSessionRetry(c, () => c.rosterView())
    assert.deepEqual(calls, ['omit', 'include'])
  })

  it('never overrides a door that is already set', () => {
    const c = createSpoolClient({ mock: false, base: 'https://h' })
    c.setDoor('token')
    c.guessDoor('session')
    assert.equal(c.door, 'token')
    assert.equal(c.doorGuessed, false)
  })

  it('a wrong guess (credentials refused, no HTTP status) falls back to discovering the door', async () => {
    const api = { door: '', doorGuessed: false, setDoor(d) { this.door = d; this.doorGuessed = false } }
    api.door = 'session'
    api.doorGuessed = true
    const seen = []
    await assert.rejects(
      withSessionRetry(api, async () => {
        seen.push(api.door)
        if (api.door === 'session') throw new TypeError('Failed to fetch')
        throw door401()
      }),
      (e) => e.status === 401 && e.token === 'view_door',
    )
    /* guess refused -> door reset -> 401 -> arming refused too -> the prompt's 401 */
    assert.deepEqual(seen, ['session', '', 'session'])
    assert.equal(api.door, '')
  })

  it('a PROVEN session door that loses the network is not reset', async () => {
    const api = { door: 'session', doorGuessed: false, setDoor(d) { this.door = d } }
    await assert.rejects(withSessionRetry(api, async () => { throw new TypeError('Failed to fetch') }))
    assert.equal(api.door, 'session')
  })

  it('the session store guesses the door before it flips to in', () => {
    const s = src('src/stores/session.ts')
    assert.match(s, /api\.guessDoor\('session'\)/)
    assert.match(s, /if \(out\.state === 'in'\) signedIn\(\)\s*\n\s*state\.value = out\.state/)
    assert.match(s, /if \(c\) signedIn\(\)\s*\n\s*state\.value = c \? 'in' : 'out'/)
  })

  it('the session probe is single-flight', () => {
    assert.match(src('src/stores/session.ts'), /if \(!probing\) \{/)
  })
})

describe('roster reads for avatars and names wait for a session and join the store read', () => {
  it('loadAvatarFiles uses the injected read instead of a raw fetch', async () => {
    resetAvatarFiles()
    let n = 0
    const FID = 'a'.repeat(64)
    const got = await loadAvatarFiles({ base: 'https://h', read: async () => { n++; return { humans: [{ human_id: 'HUM-3', avatar_file_id: FID }] } }, fetchFn: () => { throw new Error('raw fetch used') } })
    assert.deepEqual(got, { 'HUM-3': FID })
    assert.equal(n, 1)
    resetAvatarFiles()
  })

  it('SpoolAvatar and useHumanNames read through api.rosterView, gated on session in', () => {
    const av = src('src/components/SpoolAvatar.vue')
    assert.match(av, /read: \(\) => api\.rosterView\(\)/)
    assert.match(av, /if \(st !== 'in' \|\| asked\) return/)
    const names = src('src/composables/useHumanNames.ts')
    assert.match(names, /read: \(\) => api\.rosterView\(\)/)
    assert.match(names, /onMounted\(\(\) => \{ if \(session\.state === 'in'\) void load\(\) \}\)/)
  })
})

describe('attached pictures: one verified download per file per page (sharedPreview)', () => {
  it('five cards of the same file -> one load', async () => {
    resetSharedPreviews()
    let n = 0
    const load = async () => { n++; await tick(); return 'data:image/png;base64,AA' }
    const urls = await Promise.all(Array.from({ length: 5 }, () => sharedPreview('f1', load)))
    assert.equal(n, 1)
    assert.ok(urls.every((u) => u === 'data:image/png;base64,AA'))
    await sharedPreview('f1', load)
    assert.equal(n, 1, 'a revisit is served from the page cache')
  })

  it('control: no id -> no sharing', async () => {
    let n = 0
    await Promise.all([sharedPreview('', async () => { n++; return 'x' }), sharedPreview('', async () => { n++; return 'x' })])
    assert.equal(n, 2)
  })

  it('a failed load is not kept; a throwing one resolves empty', async () => {
    resetSharedPreviews()
    let n = 0
    assert.equal(await sharedPreview('f2', async () => { n++; return '' }), '')
    assert.equal(await sharedPreview('f2', async () => { n++; throw new Error('down') }), '')
    assert.equal(await sharedPreview('f2', async () => { n++; return 'ok' }), 'ok')
    assert.equal(n, 3)
  })

  it('holds at most PREVIEW_CACHE_MAX, least recently used out first', async () => {
    resetSharedPreviews()
    let n = 0
    const load = async () => { n++; return 'u' }
    await sharedPreview('keep', load)
    for (let i = 0; i < PREVIEW_CACHE_MAX - 1; i++) await sharedPreview('x' + i, load)
    await sharedPreview('keep', load) /* touch: now most recent */
    await sharedPreview('overflow', load) /* evicts x0, not keep */
    const before = n
    await sharedPreview('keep', load)
    assert.equal(n, before)
    await sharedPreview('x0', load)
    assert.equal(n, before + 1)
    resetSharedPreviews()
  })

  it('FileAttachment goes through sharedPreview', () => {
    assert.match(src('src/components/FileAttachment.vue'), /await sharedPreview\(/)
  })
})

describe('lobby: the room task and the #lobby topics are read in parallel', () => {
  it('listMessages starts before store.open resolves, admitted after it', () => {
    const s = src('src/pages/lobby.vue')
    // on a load that landed on /lobby both reads were started even earlier, at session 'in' (utils/lobby-warm)
    assert.match(s, /const topics = warm \? warm\.topics : withSessionRetry\(api, \(\) => api\.listMessages\(\{ channel: 'lobby', limit: 50 \}\)\)\n[\s\S]*?void store\.open\(id, [^\n]*\)\n\s*\.then\(\(\) => loadLobbyTopics\(topics\)\)/)
    assert.doesNotMatch(s, /store\.open\(id\)\.then\(\(\) => loadLobbyTopics\(\)\)/)
  })
})

describe('a channel page is one read when the hub inlines per_topic (027 T122)', () => {
  const T = (i) => ({ task_id: `t${i}`, first_ts: '1', last_ts: '1', count: 1, subject: 's' })
  const M = (i) => ({ cursor: `c${i}`, received_at: `2026-09-25T00:00:0${i}Z`, env: { from_box: 'box-a', msg: { v: 1, msg_id: `m${i}`, task_id: `t${i}`, ts: `2026-09-25T00:00:0${i}Z`, from: 'CLE-01', body: 'b', kind: 'note' } }, deliveries: [] })
  function hub({ inline }) {
    const calls = []
    const fn = async (url) => {
      calls.push(url)
      const u = new URL(url)
      let body
      if (u.pathname === '/v1/view/topics') {
        body = { topics: [0, 1, 2].map((i) => ({ ...T(i), ...(inline && u.searchParams.get('per_topic') ? { messages: [M(i)], messages_next: null } : {}) })), next: null }
      } else {
        const i = Number(u.pathname.split('/t').pop())
        body = { task_id: `t${i}`, messages: [M(i)], next: null }
      }
      return { ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => body }
    }
    return { fn, calls }
  }

  it('asks for per_topic=<limit> and reads no topic on its own', async () => {
    const h = hub({ inline: true })
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: h.fn })
    const page = await c.listMessages({ channel: 'lobby', limit: 30 })
    assert.equal(h.calls.length, 1)
    assert.equal(new URL(h.calls[0]).searchParams.get('per_topic'), '30')
    assert.deepEqual(page.messages.map((m) => m.msg_id), ['m0', 'm1', 'm2'])
  })

  it('control: a hub without per_topic gets the old N+1 and the SAME rows', async () => {
    const h = hub({ inline: false })
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: h.fn })
    const page = await c.listMessages({ channel: 'lobby', limit: 30 })
    assert.equal(h.calls.length, 4)
    assert.deepEqual(page.messages.map((m) => m.msg_id), ['m0', 'm1', 'm2'])
  })

  it('a limit above the hub cap never sends per_topic', async () => {
    const h = hub({ inline: true })
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: h.fn })
    await c.listMessages({ channel: 'lobby', limit: 51 })
    assert.equal(new URL(h.calls[0]).searchParams.get('per_topic'), null)
    assert.equal(h.calls.length, 4)
  })
})
