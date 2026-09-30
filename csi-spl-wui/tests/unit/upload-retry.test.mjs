import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { isUploadDoor, sessionExpiredError, uploadWithFreshToken } from '../../src/utils/upload-retry.mjs'

const door = () => Object.assign(new Error('spool 401 door'), { status: 401, token: 'door' })

/** A fake spool client: `uploadFile` succeeds only for a token in `good`. */
function fakeApi(good) {
  const calls = []
  return {
    calls,
    async uploadFile(file, token) {
      calls.push(token)
      if (good.has(token)) return { file_id: 'f', sha256: 's', bytes: 1 }
      throw door()
    },
  }
}

/** A fake live composable: hands out `first` normally, `forced` on a redial. */
function fakeLive(first, forced) {
  const forces = []
  return {
    forces,
    async freshUploadToken(force = false) {
      if (force) { forces.push(true); return forced }
      return first
    },
  }
}

describe('upload-retry (CLE-77795)', () => {
  it('recognises only the hub upload-token 401', () => {
    assert.equal(isUploadDoor(door()), true)
    assert.equal(isUploadDoor({ status: 401, token: 'view_door' }), false)
    assert.equal(isUploadDoor({ status: 403, token: 'door' }), false)
    assert.equal(isUploadDoor(new Error('x')), false)
    assert.equal(isUploadDoor(null), false)
  })

  it('uploads with the current token when it is accepted', async () => {
    const api = fakeApi(new Set(['t-ok']))
    const live = fakeLive('t-ok', 't-fresh')
    const out = await uploadWithFreshToken(api, live, 'file')
    assert.equal(out.file_id, 'f')
    assert.deepEqual(api.calls, ['t-ok']) // no retry, no redial
    assert.equal(live.forces.length, 0)
  })

  it('on 401 door, redials for a fresh token and retries once', async () => {
    // the stale token the tab held is rejected; the redialled one works
    const api = fakeApi(new Set(['t-fresh']))
    const live = fakeLive('t-stale', 't-fresh')
    const out = await uploadWithFreshToken(api, live, 'file')
    assert.equal(out.file_id, 'f')
    assert.deepEqual(api.calls, ['t-stale', 't-fresh'])
    assert.equal(live.forces.length, 1)
  })

  it('empty token from the redial (signed out) → session_expired, no second POST', async () => {
    const api = fakeApi(new Set())
    const live = fakeLive('t-stale', '')
    await assert.rejects(uploadWithFreshToken(api, live, 'file'), (e) => e.token === 'session_expired')
    assert.deepEqual(api.calls, ['t-stale']) // never posts with an empty token
  })

  it('a second 401 door after the redial → session_expired', async () => {
    const api = fakeApi(new Set()) // nothing is accepted
    const live = fakeLive('t-stale', 't-fresh')
    await assert.rejects(uploadWithFreshToken(api, live, 'file'), (e) => e.token === 'session_expired')
    assert.deepEqual(api.calls, ['t-stale', 't-fresh'])
  })

  it('a non-401 error is rethrown untouched, with no retry', async () => {
    const boom = Object.assign(new Error('spool 500'), { status: 500, token: 'internal' })
    const api = {
      calls: 0,
      async uploadFile() { this.calls++; throw boom },
    }
    const live = fakeLive('t', 't2')
    await assert.rejects(uploadWithFreshToken(api, live, 'file'), (e) => e === boom)
    assert.equal(api.calls, 1)
    assert.equal(live.forces.length, 0)
  })

  it('sessionExpiredError carries the token the composer maps', () => {
    const e = sessionExpiredError()
    assert.equal(e.token, 'session_expired')
    assert.equal(e.status, 401)
  })
})
