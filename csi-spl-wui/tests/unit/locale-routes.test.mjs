// CLE-77925: the locale route copies are made when the router is created, not
// shipped in the routes module (78 KB raw / 2.5 KB gzip initial JS). The build
// itself refuses a mismatch with what @nuxtjs/i18n made (nuxt.config.ts,
// localeRouteCopiesModule); this pins the shape and the wiring.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { createRouter, createMemoryHistory } from 'vue-router'

import {
  expandLocaleRoutes, isLocaleRouteCopy, splitLocaleRoutes, deferLocaleRoutes, registerLocaleRoutes,
} from '../../src/utils/locale-routes.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const CODES = ['bg', 'en', 'fi']
const comp = () => null

describe('locale route copies', () => {
  it('one copy per other locale, i18n order, default unprefixed', () => {
    const r = { name: 'people___en', path: '/people', component: comp, meta: { a: 1 } }
    const out = expandLocaleRoutes([r], CODES, 'en')
    assert.deepEqual(out.map((x) => [x.name, x.path]), [
      ['people___bg', '/bg/people'], ['people___en', '/people'], ['people___fi', '/fi/people'],
    ])
    assert.equal(out[1], r)
    assert.equal(out[0].component, comp)
    assert.equal(out[0].meta, r.meta)
  })

  it('the root becomes /<code>', () => {
    const out = expandLocaleRoutes([{ name: 'index___en', path: '/' }], CODES, 'en')
    assert.deepEqual(out.map((x) => x.path), ['/bg', '/', '/fi'])
  })

  it('children keep relative paths and are renamed', () => {
    const r = { name: 'ts___en', path: '/ts', children: [{ name: 'ts-members___en', path: 'members' }, { path: '' }] }
    const bg = expandLocaleRoutes([r], CODES, 'en')[0]
    assert.deepEqual(bg.children, [{ name: 'ts-members___bg', path: 'members' }, { path: '' }])
    assert.equal(r.children[0].name, 'ts-members___en')
  })

  it('a record that is not a default-locale one passes through', () => {
    const r = { name: 'catch', path: '/:x(.*)*' }
    assert.deepEqual(expandLocaleRoutes([r], CODES, 'en'), [r])
  })

  it('isLocaleRouteCopy: only another known locale', () => {
    assert.equal(isLocaleRouteCopy({ name: 'people___bg' }, CODES, 'en'), true)
    assert.equal(isLocaleRouteCopy({ name: 'people___en' }, CODES, 'en'), false)
    assert.equal(isLocaleRouteCopy({ name: 'people___xx' }, CODES, 'en'), false)
    assert.equal(isLocaleRouteCopy({ path: '/x' }, CODES, 'en'), false)
  })

  it('the router and the build are wired to it', () => {
    const opts = readFileSync(join(WUI, 'src/app/router.options.ts'), 'utf8')
    assert.match(opts, /expandLocaleRoutes\(/)
    const cfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
    assert.match(cfg, /modules: \["@nuxtjs\/i18n", "@pinia\/nuxt", localeRouteCopiesModule[,\]]/)
    assert.match(cfg, /expandLocaleRoutes does not rebuild i18n's routes/)
  })

  // P3-14: the browser router starts with the default + URL locale only.
  const ALL = ['bg', 'en', 'fi', 'sv']
  const KEPT = () => [
    { name: 'index___en', path: '/', component: comp },
    { name: 'people-id___en', path: '/people/:id()', component: comp },
    { name: 'help-page___en', path: '/help/:page?', component: comp },
    ...ALL.map((code) => ({
      path: code === 'en' ? '/ts' : `/${code}/ts`, component: comp,
      children: [{ name: `ts___${code}`, path: '', component: comp }, { name: `ts-members___${code}`, path: 'members', component: comp }],
    })),
  ]
  const names = (list) => list.map((r) => r.name || r.path)

  it('split: now = default + active + no locale, now + later = expand', () => {
    const kept = KEPT()
    const { now, later } = splitLocaleRoutes(kept, ALL, 'en', 'fi')
    assert.deepEqual(names(now), ['index___en', 'index___fi', 'people-id___en', 'people-id___fi',
      'help-page___en', 'help-page___fi', '/ts', '/fi/ts'])
    const all = expandLocaleRoutes(kept, ALL, 'en')
    assert.deepEqual(new Set(names([...now, ...later()])), new Set(names(all)))
    assert.equal(now.length + later().length, all.length)
    assert.deepEqual(names(splitLocaleRoutes(kept, ALL, 'en', '').now), ['index___en', 'people-id___en', 'help-page___en', '/ts'])
  })

  it('a router made from `now` and then given `later` resolves like the full one', () => {
    const kept = KEPT()
    const full = createRouter({ history: createMemoryHistory(), routes: expandLocaleRoutes(kept, ALL, 'en') })
    const { now, later } = splitLocaleRoutes(kept, ALL, 'en', 'bg')
    const lazy = createRouter({ history: createMemoryHistory(), routes: now })
    assert.equal(lazy.resolve('/fi/people/x').matched.length, 0, 'fi is not there before registering')
    assert.equal(lazy.resolve('/bg/people/x').name, 'people-id___bg')
    deferLocaleRoutes(later)
    assert.equal(registerLocaleRoutes(lazy), true)
    assert.equal(registerLocaleRoutes(lazy), false, 'once')
    for (const p of ['/', '/bg', '/fi', '/sv/people/7', '/people/7', '/help', '/fi/help/a', '/ts', '/fi/ts/members', '/sv/ts', '/nope']) {
      const a = full.resolve(p)
      const b = lazy.resolve(p)
      assert.deepEqual([b.name, b.matched.length, b.params], [a.name, a.matched.length, a.params], p)
    }
    assert.equal(lazy.getRoutes().length, full.getRoutes().length)
  })

  it('the client router splits, the plugin and both locale switchers register', () => {
    const opts = readFileSync(join(WUI, 'src/app/router.options.ts'), 'utf8')
    assert.match(opts, /if \(import\.meta\.server\) return expandLocaleRoutes\(/)
    assert.match(opts, /splitLocaleRoutes\(/)
    const plug = readFileSync(join(WUI, 'src/plugins/locale-routes.client.ts'), 'utf8')
    assert.match(plug, /!to\.matched\.length && registerLocaleRoutes\(router\)\) return to\.fullPath/)
    assert.match(plug, /app:mounted/)
    for (const f of ['src/composables/useLocaleSwitch.ts', 'src/plugins/preferred-locale.client.ts']) {
      const src = readFileSync(join(WUI, f), 'utf8')
      assert.ok(src.indexOf('registerLocaleRoutes(') > 0 && src.indexOf('registerLocaleRoutes(') < src.lastIndexOf('switchLocalePath'), f)
    }
  })
})

