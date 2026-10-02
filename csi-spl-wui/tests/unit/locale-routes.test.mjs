// CLE-77925: the locale route copies are made when the router is created, not
// shipped in the routes module (78 KB raw / 2.5 KB gzip initial JS). The build
// itself refuses a mismatch with what @nuxtjs/i18n made (nuxt.config.ts,
// localeRouteCopiesModule); this pins the shape and the wiring.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { expandLocaleRoutes, isLocaleRouteCopy } from '../../src/utils/locale-routes.mjs'

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
})
