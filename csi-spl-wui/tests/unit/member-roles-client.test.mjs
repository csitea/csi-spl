// SPL-5056: the member role set against the hub's real answers. The golden file
// is generated from the hub's handlers (hub/member_roles_answers_golden_test.go),
// so this fails when the client reads a shape the hub does not send, which the
// mock bundle's e2e cannot see. The mock is held to the same answers below.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { lazySpoolMethods } from '../../src/utils/spool-client-lazy.mjs'
import { normalizeDirectory, userErrorKey } from '../../src/utils/tenant-users.mjs'
import { createMockDirectory } from '../../src/utils/tenant-users-mock.mjs'
import { roleOptions, rolesDirty, toggleRole } from '../../src/utils/member-roles.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const ANSWERS = JSON.parse(readFileSync(join(WUI, '../csi-spl-api/src/go/spool-hub-api/internal/hub/testdata/member_roles_answers.golden.json'), 'utf8'))

describe('the client reads what the hub answers', () => {
  it('a listed member carries the whole set, the primary first', () => {
    const dir = normalizeDirectory({ members: [ANSWERS.list_row.body], roles: ANSWERS.list_roles.body })
    assert.equal(dir.members[0].role, 'tester')
    assert.deepEqual(dir.members[0].roles, ['tester', 'developer'])
    assert.equal(dir.members[0].manageable, true)
    assert.ok(dir.roles.some((r) => r.id === 'developer' && r.grantable))
    assert.ok(dir.roles.some((r) => r.id === 'biz_owner' && !r.grantable), 'an admin cannot grant biz_owner')
  })

  it('PUT .../roles sends the keys the hub decodes', async () => {
    const sent = []
    const live = async (path, init) => { sent.push({ path, init }); return ANSWERS.set.body }
    const res = await lazySpoolMethods.setTenantUserRoles({ live, mock: false }, 'HUM-3', ['developer', 'tester'], 'tester', ['developer'])
    assert.equal(sent[0].path, '/v1/members/HUM-3/roles')
    assert.equal(sent[0].init.method, 'PUT')
    assert.deepEqual(JSON.parse(sent[0].init.body), { roles: ['developer', 'tester'], primary: 'tester', from_roles: ['developer'] })
    assert.deepEqual(res.roles, ['tester', 'developer'])
  })

  for (const [name, status, key] of [
    ['stale_from_roles', 409, 'users.error.role_changed'],
    ['last_owner', 409, 'users.error.last_owner'],
    ['not_grantable', 403, 'users.error.forbidden'],
    ['role_not_in_tenant', 400, 'users.error.bad_role'],
    ['empty_set', 400, 'users.error.bad_role'],
  ]) {
    it(`${name}: the hub's refusal has words`, () => {
      assert.equal(ANSWERS[name].status, status)
      assert.equal(userErrorKey({ token: ANSWERS[name].body.error }), key)
    })
  }
})

describe('the mock answers in the hub\'s shape', () => {
  it('a set answers the hub\'s keys, the primary first', () => {
    const got = createMockDirectory().setRoles('HUM-3', ['developer', 'tester'], 'tester', ['developer'])
    assert.deepEqual(Object.keys(got).sort(), [...Object.keys(ANSWERS.set.body), 'tenant_id'].sort())
    assert.deepEqual(got.roles, ANSWERS.set.body.roles)
  })

  it('the listed row carries every key the client reads for roles', () => {
    const row = createMockDirectory().list().members.find((m) => m.human_id === 'HUM-3')
    for (const key of ['role', 'roles', 'manageable']) assert.ok(key in ANSWERS.list_row.body && key in row, key)
  })

  const refused = (fn, token) => assert.throws(fn, (e) => e.token === token)
  it('CONTROLS: the hub\'s refusals', () => {
    const m = createMockDirectory()
    refused(() => m.setRoles('HUM-3', ['tester'], '', ['tester']), 'role_changed')
    refused(() => m.setRoles('HUM-3', ['biz_owner'], '', ['developer']), 'forbidden')
    refused(() => m.setRoles('HUM-3', [], '', ['developer']), 'bad_role')
    refused(() => m.setRoles('HUM-3', ['developer'], 'tester', ['developer']), 'bad_role')
    refused(() => m.setRoles('HUM-1', ['tester'], '', ['admin']), 'last_admin')
  })
})

describe('the picker', () => {
  const pick = (roles, primary) => ({ roles, primary })
  it('adds a role and keeps the primary', () => {
    assert.deepEqual(toggleRole(pick(['developer'], 'developer'), 'tester', true), pick(['developer', 'tester'], 'developer'))
  })
  it('dropping the primary moves it to a role still held', () => {
    assert.deepEqual(toggleRole(pick(['developer', 'tester'], 'developer'), 'developer', false), pick(['tester'], 'tester'))
  })
  it('an exclusive role holds the set alone, and leaves it when another is picked', () => {
    assert.deepEqual(toggleRole(pick(['developer', 'tester'], 'tester'), 'demo_user', true), pick(['demo_user'], 'demo_user'))
    assert.deepEqual(toggleRole(pick(['channel_guest'], 'channel_guest'), 'developer', true), pick(['developer'], 'developer'))
  })
  it('offers the grantable roles and a held one the actor cannot grant as locked; CONTROL: no other', () => {
    const catalogue = [{ id: 'biz_owner', grantable: false }, { id: 'product_owner', grantable: false }, { id: 'tester', grantable: true }]
    assert.deepEqual(roleOptions(catalogue, ['biz_owner', 'gone_role']), [
      { id: 'biz_owner', locked: true },
      { id: 'tester', locked: false },
      { id: 'gone_role', locked: true },
    ])
  })
  it('is dirty on a changed set or primary, and never on an empty one', () => {
    const m = { role: 'developer', roles: ['developer', 'tester'] }
    assert.equal(rolesDirty(m, pick(['tester', 'developer'], 'developer')), false)
    assert.equal(rolesDirty(m, pick(['developer', 'tester'], 'tester')), true)
    assert.equal(rolesDirty(m, pick(['developer'], 'developer')), true)
    assert.equal(rolesDirty(m, pick([], '')), false)
  })
})
