// SPL-1006: an open tab picks up a new deploy safely (utils/build-watch.mjs).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { CHECK_EVERY_MS, isNewer, normCommit } from '../../src/utils/build-watch.mjs'
import { decide, pageBusy, readLiveCommit } from '../../src/utils/build-watch-rules.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const A = '0123456789abcdef0123456789abcdef01234567'
const B = 'fedcba9876543210fedcba9876543210fedcba98'

/* a DOM just deep enough for pageBusy: elements answer the few properties it reads */
function el(props = {}) {
  return { getAttribute: () => null, tagName: 'INPUT', type: 'text', value: '', disabled: false, readOnly: false, isContentEditable: false, textContent: '', closest: () => null, getClientRects: () => [{}], ...props }
}
function doc({ fields = [], dialogs = [], pending = false, active = null } = {}) {
  return {
    activeElement: active,
    querySelectorAll: (sel) => (sel.includes('role=dialog') ? dialogs : fields),
    querySelector: (sel) => (sel === '[data-pending=true]' && pending ? {} : null),
  }
}

describe('build watch: commits', () => {
  it('normalises a sha and rejects anything else', () => {
    assert.equal(normCommit(` ${A.toUpperCase()} `), A)
    assert.equal(normCommit('main'), '')
    assert.equal(normCommit(''), '')
  })
  it('a different commit is newer; the same one (full or short) is not', () => {
    assert.equal(isNewer(A, B), true)
    assert.equal(isNewer(A, A), false)
    assert.equal(isNewer(A, A.slice(0, 8)), false)
  })
  it('CONTROL: no running commit (lde) or no live one never counts as newer', () => {
    assert.equal(isNewer('', B), false)
    assert.equal(isNewer(A, ''), false)
  })
})

describe('build watch: decide', () => {
  it('idle -> reload, busy -> prompt, same -> none', () => {
    assert.equal(decide({ running: A, live: B, busy: false }), 'reload')
    assert.equal(decide({ running: A, live: B, busy: true }), 'prompt')
    assert.equal(decide({ running: A, live: A, busy: false }), 'none')
  })
  it('never reloads twice for the same commit (the guard): the bar only', () => {
    assert.equal(decide({ running: A, live: B, busy: false, guard: B }), 'prompt')
  })
  it('a guard for an OLDER commit does not block the next deploy', () => {
    const C = '1111111111111111111111111111111111111111'
    assert.equal(decide({ running: A, live: C, busy: false, guard: B }), 'reload')
  })
  it('checks every 5 minutes', () => assert.equal(CHECK_EVERY_MS, 300_000))
})

describe('build watch: is anything being typed?', () => {
  it('an empty page is idle', () => {
    assert.equal(pageBusy(doc({ fields: [el(), el({ tagName: 'TEXTAREA' })] })), false)
  })
  it('a draft in a textarea, a text input or a contenteditable is busy', () => {
    assert.equal(pageBusy(doc({ fields: [el({ tagName: 'TEXTAREA', value: 'half a thought' })] })), true)
    assert.equal(pageBusy(doc({ fields: [el({ value: 'x' })] })), true)
    assert.equal(pageBusy(doc({ fields: [el({ tagName: 'DIV', isContentEditable: true, textContent: 'draft' })] })), true)
  })
  it('an open dialog and a message still in flight are busy', () => {
    assert.equal(pageBusy(doc({ dialogs: [el({ tagName: 'DIV' })] })), true)
    assert.equal(pageBusy(doc({ pending: true })), true)
  })
  it('CONTROL: a closed (unpainted) dialog, a checkbox, a disabled field and the bar itself are not', () => {
    assert.equal(pageBusy(doc({ dialogs: [el({ tagName: 'DIV', getClientRects: () => [] })] })), false)
    assert.equal(pageBusy(doc({ fields: [el({ type: 'checkbox', value: 'on' })] })), false)
    assert.equal(pageBusy(doc({ fields: [el({ value: 'x', disabled: true })] })), false)
    assert.equal(pageBusy(doc({ fields: [el({ value: 'x', closest: () => ({}) })] })), false)
    const combo = (expanded) => el({ value: 'English', getAttribute: (k) => ({ role: 'combobox', 'aria-expanded': expanded })[k] ?? null })
    assert.equal(pageBusy(doc({ fields: [combo('false')] })), false)
    assert.equal(pageBusy(doc({ fields: [combo('true')] })), true)
  })
  /* HUM-27 (csi-rel, 2026-09-28): switching the keyboard's typing language
     bounces the window focus; the focus check found a newer deploy and an
     EMPTY composer read as idle - the tab reloaded and the keyboard closed */
  it('HUM-27: the reader in an EMPTY text field is busy (the keyboard is up)', () => {
    const box = el({ tagName: 'TEXTAREA' })
    assert.equal(pageBusy(doc({ fields: [box], active: box })), true)
    assert.equal(decide({ running: A, live: B, busy: pageBusy(doc({ fields: [box], active: box })) }), 'prompt')
    const input = el()
    assert.equal(pageBusy(doc({ fields: [input], active: input })), true)
    const editor = el({ tagName: 'DIV', isContentEditable: true })
    assert.equal(pageBusy(doc({ active: editor })), true)
  })
  it('HUM-27 CONTROL: focus on a button, a checkbox, a disabled / read-only field, a closed combobox or an ignored field is idle', () => {
    const empty = el({ tagName: 'TEXTAREA' })
    assert.equal(pageBusy(doc({ fields: [empty], active: el({ tagName: 'BUTTON' }) })), false)
    assert.equal(pageBusy(doc({ fields: [empty], active: el({ type: 'checkbox' }) })), false)
    assert.equal(pageBusy(doc({ active: el({ tagName: 'TEXTAREA', disabled: true }) })), false)
    assert.equal(pageBusy(doc({ active: el({ readOnly: true }) })), false)
    assert.equal(pageBusy(doc({ active: el({ getAttribute: (k) => ({ role: 'combobox', 'aria-expanded': 'false' })[k] ?? null }) })), false)
    assert.equal(pageBusy(doc({ active: el({ tagName: 'TEXTAREA', closest: () => ({}) }) })), false)
    assert.equal(pageBusy(doc({ fields: [empty], active: null })), false)
  })
})

describe('build watch: /build.json', () => {
  it('reads the commit with cache no-store', async () => {
    let init = null
    const r = await readLiveCommit(async (_u, i) => { init = i; return { ok: true, json: async () => ({ commit: B }) } })
    assert.equal(r.commit, B)
    assert.equal(init.cache, 'no-store')
  })
  it('CONTROL: offline, 404 or junk reads as nothing', async () => {
    assert.equal((await readLiveCommit(async () => { throw new Error('offline') })).commit, '')
    assert.equal((await readLiveCommit(async () => ({ ok: false }))).commit, '')
    assert.equal((await readLiveCommit(async () => ({ ok: true, json: async () => ({ commit: 'x' }) }))).commit, '')
  })
})

describe('build watch: wiring', () => {
  it('the build bakes its commit in (GITHUB_SHA at nuxt generate)', () => {
    assert.match(read('nuxt.config.ts'), /buildCommit:.*GITHUB_SHA/)
  })
  it('the plugin listens to visibility, focus and bfcache, and sets window.__BUILD__', () => {
    /* the polling loads once the app is ready (utils/build-watch-run.ts, off
       the initial download); the plugin sets __BUILD__ and starts it */
    const plugin = read('src/plugins/build-watch.client.ts')
    const src = plugin + read('src/utils/build-watch-run.ts')
    for (const s of ["'visibilitychange'", "'focus'", "'pageshow'", 'window.__BUILD__', 'CHECK_EVERY_MS']) assert.ok(src.includes(s), s)
    assert.match(plugin, /onNuxtReady\(\(\) => void import\('~\/utils\/build-watch-run'\)/)
    assert.doesNotMatch(plugin, /from '~\/utils\/build-watch\.mjs'/)
  })
  it('the bar is EAGER (an old build\'s lazy chunks are gone after a deploy)', () => {
    const app = read('src/app.vue')
    assert.match(app, /<BuildUpdateBar \/>/)
    assert.doesNotMatch(app, /LazyBuildUpdateBar/)
  })
  it('every locale says it', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const b = JSON.parse(readFileSync(join(dir, f), 'utf8')).build || {}
      assert.ok(b.new_version && b.reload && /\{commit\}/.test(b.newer_live || ''), f)
    }
  })

  it('r3-07: a hung build.json read gives up after timeoutMs as "nothing to do"', async () => {
    const calls = []
    assert.deepEqual(await readLiveCommit(hang(calls), { timeoutMs: 5 }), { commit: '', stamp: null })
    assert.ok(calls[0][1].signal, 'the read carries an abort signal')
  })
})

/* a fetch that never answers, but honours init.signal like the real one */
const hang = (calls = []) => (url, init = {}) => {
  calls.push([url, init])
  return new Promise((_, reject) => {
    if (init.signal) init.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))
  })
}
