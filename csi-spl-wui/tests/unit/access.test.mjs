// specs/025 FR-006/FR-008: the WUI's reading of GET /v1/view/me.
// Run: node tests/unit/access.test.mjs
import { accessAllows, canRemoveMember, normalizeMe, roleLabelKey, ROLE_IDS } from '../../src/utils/access.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

console.log('access')
const tester = normalizeMe({ human_id: 'HUM-3', tenant_id: 't1', role: 'tester', tenant_owner: false, permissions: ['notes.send', 'topics.read'] })
ok('tester reads and sends notes', accessAllows(tester, 'topics.read') && accessAllows(tester, 'notes.send'))
ok('CONTROL: tester is not offered channel create', !accessAllows(tester, 'channels.manage'))
ok('CONTROL: tester is not offered agent commands', !accessAllows(tester, 'agents.command'))
const owner = normalizeMe({ human_id: 'HUM-1', role: 'biz_owner', tenant_owner: true, permissions: ['billing.manage', 'channels.manage'] })
ok('owner flags', owner.tenantOwner === true && owner.role === 'biz_owner' && accessAllows(owner, 'billing.manage'))
const guest = normalizeMe({ human_id: null, tenant_id: 't1', role: null, tenant_owner: null, permissions: null })
ok('door-off guest: unrestricted, no role', guest.permissions === null && guest.role === null && accessAllows(guest, 'channels.manage'))
ok('no answer (old hub / error): fails open', accessAllows(null, 'channels.manage') && accessAllows(normalizeMe(undefined), 'x'))
ok('junk permissions are dropped', normalizeMe({ permissions: ['a', 3, null] }).permissions.length === 1)
ok('role keys for the eight roles', ROLE_IDS.length === 8 && ROLE_IDS.every((r) => roleLabelKey(r) === `role.${r}`))
ok('unknown / empty role has no key', roleLabelKey('custom_x') === '' && roleLabelKey(null) === '')

// CLE-77799: the People card "Remove from workspace" guard (owner 1fc29f99).
const admin = normalizeMe({ human_id: 'HUM-1', role: 'admin', permissions: ['members.invite', 'topics.read'] })
const plain = normalizeMe({ human_id: 'HUM-9', role: 'regular_user', permissions: ['topics.read'] })
ok('admin may remove another member', canRemoveMember(admin, { targetId: 'HUM-3', selfId: 'HUM-1' }))
ok('CONTROL: a regular user is offered no remove', !canRemoveMember(plain, { targetId: 'HUM-3', selfId: 'HUM-9' }))
ok('never remove yourself', !canRemoveMember(admin, { targetId: 'HUM-1', selfId: 'HUM-1' }))
ok('never the last owner', !canRemoveMember(admin, { targetId: 'HUM-2', selfId: 'HUM-1', targetIsOwner: true, ownerCount: 1 }))
ok('an owner among several may be removed', canRemoveMember(admin, { targetId: 'HUM-2', selfId: 'HUM-1', targetIsOwner: true, ownerCount: 2 }))
ok('no target id: no action', !canRemoveMember(admin, { targetId: '', selfId: 'HUM-1' }))
ok('fails open when the role is unknown (mock/old hub), hub is the control', canRemoveMember(null, { targetId: 'HUM-3', selfId: 'HUM-1' }))
const s = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', s.ok, s.why)

console.log(failed ? `access: ${failed} FAILED` : 'access: all OK')
if (failed) process.exitCode = 1
