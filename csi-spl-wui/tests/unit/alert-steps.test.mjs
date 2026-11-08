// alertSteps' four inputs, run for real through the store (r53-05): no test ran
// it, so nothing held that each input reaches the alert a message raises. The
// store and notify.mjs are real; pinia, the names composable, the Nuxt app and
// the browser's Notification are stubbed.
//
// Run: node --test tests/unit/alert-steps.test.mjs
import { before, beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { computed, ref, watch } from 'vue'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'

const NAMES = { 'HUM-1': 'Member One', 'HUM-7': 'Member Seven' }
const MENTION = { msg_id: 'M1', from: 'HUM-7', channel: 'general', body: '@HUM-1 see @HUM-7' }

let useNotificationStore
let shown

/** A new store with the browser's permission granted and the bell on. */
function store() {
  const s = useNotificationStore()
  s.permission.value = 'granted'
  return s
}

/** The one alert a mention of the reader raises. */
function alertOf(s) {
  s.ingest(MENTION, { selfId: 'HUM-1' })
  assert.equal(shown.length, 1)
  return shown[0]
}

before(async () => {
  Object.assign(globalThis, {
    computed,
    ref,
    watch,
    useNuxtApp: () => ({
      $i18n: { t: (key, params) => `${key}|${params.from}` },
      $localePath: (path) => `/en${path}`,
    }),
    Notification: class {
      constructor(title, opts) { shown.push({ title, opts }) }
    },
  })
  ;({ useNotificationStore } = await importTsStubbed('src/stores/notification.ts', {
    pinia: { defineStore: (_, fn) => fn, skipHydrate: (x) => x },
    '~/composables/useHumanNames': { useHumanNames: () => ({ names: ref(NAMES) }) },
  }))
})

beforeEach(() => { shown = [] })

describe('alertSteps inputs', () => {
  it('A: with the alerts off a message raises no notification', () => {
    const s = store()
    s.alertsEnabled.value = false
    s.ingest(MENTION, { selfId: 'HUM-1' })
    assert.deepEqual(shown, [])
  })

  it('N: the url a tap opens has its locale prefix', () => {
    assert.equal(alertOf(store()).opts.data.url, '/en/m/m1')
  })

  it('I: the title is the translated key', () => {
    assert.match(alertOf(store()).title, /^notify\.title_mention\|/)
  })

  /* the sender is held as "not the raw id": the title is the translation's, and I holds that */
  it('H: the sender and the body read the member name', () => {
    const { title, opts } = alertOf(store())
    assert.doesNotMatch(title, /HUM-7/)
    assert.equal(opts.body, '@Member One see @Member Seven')
  })
})
