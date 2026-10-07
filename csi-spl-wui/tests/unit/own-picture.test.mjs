// t1 ccaee528: a person changes their own picture from the account menu.
// The request half (src/utils/own-picture.mjs): PUT the picked file to the
// hub's /api/v1/auth/avatar, DELETE to go back to the IdP picture, and the
// hub's refusals as messages. CONTROLS: a wrong type or an over-cap file never
// reaches the hub; a 415 / 413 / 5xx / network error is never "stored".
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  OWN_PICTURE_MAX_BYTES, deleteOwnPicture, ownPictureAnswer, ownPictureProblem, putOwnPicture,
} from '../../src/utils/own-picture.mjs'

const png = { type: 'image/png', size: 1200 }

function recorder(status) {
  const calls = []
  const fetchFn = async (url, init) => {
    calls.push({ url, ...init })
    if (status === 'throw') throw new TypeError('network')
    return { status }
  }
  return { calls, fetchFn }
}

describe('own picture: the picked file', () => {
  it('png, jpeg and webp up to the hub cap are fine', () => {
    for (const type of ['image/png', 'image/jpeg', 'image/webp']) assert.equal(ownPictureProblem({ type, size: 10 }), '')
    assert.equal(ownPictureProblem({ type: 'image/png', size: OWN_PICTURE_MAX_BYTES }), '')
  })

  it('CONTROL: gif, svg, no type or no file is a type problem; empty or over the cap a size one', () => {
    for (const type of ['image/gif', 'image/svg+xml', '', 'text/plain']) assert.equal(ownPictureProblem({ type, size: 10 }), 'type')
    assert.equal(ownPictureProblem(null), 'type')
    assert.equal(ownPictureProblem({ type: 'image/png', size: 0 }), 'size')
    assert.equal(ownPictureProblem({ type: 'image/png', size: OWN_PICTURE_MAX_BYTES + 1 }), 'size')
  })

  it('the cap is the hub\'s auth.AvatarMaxBytes', () => {
    const idp = readFileSync(new URL('../../../csi-spl-api/src/go/spool-hub-api/internal/auth/idp.go', import.meta.url), 'utf8')
    assert.match(idp, /AvatarMaxBytes\s+=\s+256 << 10/)
    assert.equal(OWN_PICTURE_MAX_BYTES, 256 << 10)
  })
})

describe('own picture: the hub requests', () => {
  it('PUT sends the file itself, with its type and the session cookie, to the auth base', async () => {
    const { calls, fetchFn } = recorder(204)
    assert.equal(await putOwnPicture('https://api.example.com/', png, fetchFn), '')
    assert.equal(calls.length, 1)
    assert.equal(calls[0].url, 'https://api.example.com/api/v1/auth/avatar')
    assert.equal(calls[0].method, 'PUT')
    assert.equal(calls[0].credentials, 'include')
    assert.equal(calls[0].headers['Content-Type'], 'image/png')
    assert.equal(calls[0].body, png)
  })

  it('CONTROL: a refused file never reaches the hub', async () => {
    const { calls, fetchFn } = recorder(204)
    assert.equal(await putOwnPicture('', { type: 'image/gif', size: 10 }, fetchFn), 'type')
    assert.equal(await putOwnPicture('', { type: 'image/png', size: OWN_PICTURE_MAX_BYTES + 1 }, fetchFn), 'size')
    assert.equal(calls.length, 0)
  })

  it('CONTROL: the hub\'s refusals and failures are never "stored"', async () => {
    assert.equal(await putOwnPicture('', png, recorder(415).fetchFn), 'type')
    assert.equal(await putOwnPicture('', png, recorder(413).fetchFn), 'size')
    for (const s of [401, 403, 409, 503, 'throw']) assert.equal(await putOwnPicture('', png, recorder(s).fetchFn), 'failed', String(s))
    assert.equal(ownPictureAnswer(500), 'failed')
  })

  it('DELETE goes back to the IdP picture; a failure says so', async () => {
    const ok = recorder(204)
    assert.equal(await deleteOwnPicture('/', ok.fetchFn), '')
    assert.deepEqual([ok.calls[0].url, ok.calls[0].method, ok.calls[0].credentials], ['/api/v1/auth/avatar', 'DELETE', 'include'])
    for (const s of [401, 503, 'throw']) assert.equal(await deleteOwnPicture('', recorder(s).fetchFn), 'failed', String(s))
  })
})

describe('own picture: the account menu', () => {
  const menu = readFileSync(new URL('../../src/components/UserMenu.vue', import.meta.url), 'utf8')
  it('loads the request code lazily, never as a static import (initial chunk budget)', () => {
    assert.match(menu, /await import\('~\/utils\/own-picture\.mjs'\)/)
    assert.doesNotMatch(menu, /^import .*own-picture/m)
  })
  it('every locale names the items and the three refusals', () => {
    const dir = new URL('../../i18n/locales/', import.meta.url)
    for (const loc of ['en', 'bg', 'el', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const um = JSON.parse(readFileSync(new URL(`${loc}.json`, dir), 'utf8')).user_menu
      for (const k of ['change_picture', 'remove_picture', 'picture_type', 'picture_size', 'picture_failed']) {
        assert.ok(typeof um[k] === 'string' && um[k].trim(), `${loc}: user_menu.${k}`)
      }
    }
  })
})
