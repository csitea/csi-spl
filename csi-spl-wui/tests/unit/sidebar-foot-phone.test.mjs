// p20-02 (perf round 20, SPL-2402): the sidebar footer's clock host check
// (`measureFoot`, useSidebarVersion.ts) is desktop-only by design (be316fdc).
// On a phone its answer is always false, so it must be given before any
// layout read: a mount and a route change read 0 rects and 0 computed styles
// and observe nothing. On a desktop the clock still moves to the foot row
// (the CONTROL). The composable runs for real (Vue's own runtime-core under a
// no-op renderer); only the DOM it touches is faked, with counting getters.
//
// Run: node tests/unit/sidebar-foot-phone.test.mjs
import { describe, it, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { createRenderer, defineComponent, h, nextTick, reactive, ref, computed } from 'vue'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'

const reads = { rect: 0, style: 0, observed: 0 }
const frames = []
const route = reactive({ fullPath: '/c/general' })
/* every mount is unmounted even when its case fails, so no watcher leaks into the next */
const mounted = []

class FakeResizeObserver {
  constructor(cb) { this.cb = cb }
  observe() { reads.observed++ }
  disconnect() {}
}

function fakeDom() {
  const row = {
    getBoundingClientRect() { reads.rect++; return { width: 260, height: 32, top: 800, left: 0 } },
  }
  const wrap = { closest: (sel) => (sel === '.foot-row' ? row : null) }
  return { row, wrap }
}

/* the watchers' nextTick, then their frame, then what the frame changed */
async function flushFrames() {
  for (let i = 0; i < 3; i++) {
    await nextTick()
    while (frames.length) frames.shift()()
  }
}

/* a renderer whose nodes are plain objects: enough to run setup and the hooks */
const { createApp } = createRenderer({
  createElement: () => ({}), createText: () => ({}), createComment: () => ({}),
  insert() {}, remove() {}, setText() {}, setElementText() {}, patchProp() {},
  parentNode: () => null, nextSibling: () => null,
})

async function mountFoot(phoneAtStart) {
  const clockHost = { foot: ref(false), strip: ref(false), bar: computed(() => false) }
  const { useSidebarVersion } = await importTsStubbed('src/composables/useSidebarVersion.ts', {
    '~/composables/useClockHost': { useClockHost: () => clockHost },
    '~/composables/useBuildWatch': { useBuildWatch: () => ref({ running: '', live: '' }) },
    '~/composables/useCopyText': { useCopyText: () => ({ copied: ref(''), copy: async () => {} }) },
    '~/utils/build-stamp.mjs': { buildStampText: () => '', readBuildStamp: async () => null, shortCommit: (s) => s },
  })
  const phone = ref(phoneAtStart)
  const { wrap } = fakeDom()
  const vsWrapEl = ref(wrap)
  const app = createApp(defineComponent({
    setup() {
      useSidebarVersion(phone, { overlay() {} }, vsWrapEl)
      return () => h('div')
    },
  }))
  app.mount({})
  mounted.push(app)
  await flushFrames()
  return { phone, clockHost }
}

beforeEach(() => {
  reads.rect = 0; reads.style = 0; reads.observed = 0
  frames.length = 0
  route.fullPath = '/c/general'
  globalThis.useRoute = () => route
  globalThis.useRuntimeConfig = () => ({ public: { appVersion: 'v1.0.0' } })
  globalThis.requestAnimationFrame = (fn) => { frames.push(fn); return frames.length }
  globalThis.ResizeObserver = FakeResizeObserver
  globalThis.getComputedStyle = () => { reads.style++; return { visibility: 'visible' } }
})

afterEach(() => { while (mounted.length) mounted.pop().unmount() })

describe('the sidebar foot clock on a phone reads no layout', () => {
  it('mount + a route change: 0 rects, 0 computed styles, nothing observed', async () => {
    const { clockHost } = await mountFoot(true)
    route.fullPath = '/c/random'
    await flushFrames()
    assert.deepEqual(reads, { rect: 0, style: 0, observed: 0 })
    assert.equal(clockHost.foot.value, false)
  })

  it('CONTROL: on a desktop the clock moves to the foot row, and a route change re-measures', async () => {
    const { clockHost } = await mountFoot(false)
    assert.equal(clockHost.foot.value, true)
    assert.ok(reads.rect >= 1 && reads.style >= 1, JSON.stringify(reads))
    assert.equal(reads.observed, 1)
    const before = reads.rect
    route.fullPath = '/c/random'
    await flushFrames()
    assert.equal(reads.rect, before + 1)
    mounted.pop().unmount()
    assert.equal(clockHost.foot.value, false)
  })

  it('crossing the phone width drops the clock without a read, and back attaches the observer', async () => {
    const { phone, clockHost } = await mountFoot(false)
    const at = { ...reads }
    phone.value = true
    await flushFrames()
    assert.equal(clockHost.foot.value, false)
    assert.equal(reads.rect, at.rect)
    assert.equal(reads.style, at.style)
    phone.value = false
    await flushFrames()
    assert.equal(clockHost.foot.value, true)
    assert.equal(reads.observed, at.observed + 1)
  })
})
