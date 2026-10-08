// Spec 073 4.6 / 4.7 (spec 108 T010): the join-token panel's helpers and the
// mock hub. The panel shows only when the session holds agents.join: an
// admin's permission list does, a biz_owner's (keys.manage, no agents.join)
// does not. The browser half is tests/e2e/tenant-settings.test.mjs step 7b.
// Run: node tests/unit/join-tokens.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  AGENTS_JOIN, canJoinAgents, joinCountdown, joinMemberOptions, joinMintBody, joinTokenRows, seatedBoxes,
} from '../../src/utils/join-tokens.mjs'
import { createMockJoinTokens } from '../../src/utils/join-tokens-mock.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('canJoinAgents', () => {
  it('admin (holds agents.join) sees the controls', () => {
    assert.equal(canJoinAgents({ permissions: ['keys.manage', AGENTS_JOIN] }), true)
  })
  it('biz_owner (keys.manage, no agents.join) does not', () => {
    assert.equal(canJoinAgents({ permissions: ['keys.manage', 'members.invite', 'tenant.settings'] }), false)
  })
  it('no permission list fails open, like accessAllows (the hub 403 is the control)', () => {
    assert.equal(canJoinAgents(null), true)
    assert.equal(canJoinAgents({ permissions: null }), true)
  })
  it('the permission name matches the hub rbac.AgentsJoin', () => {
    assert.match(src('../csi-spl-api/src/go/spool-hub-api/internal/rbac/rbac.go'), /AgentsJoin\s*=\s*"agents\.join"/)
  })
})

describe('joinTokenRows', () => {
  it('normalizes, drops id-less rows, open first then by expiry', () => {
    const rows = joinTokenRows({ tokens: [
      { id: 'cccccccc', state: 'revoked', expires_at: '2026-10-08T10:00:00Z' },
      { id: 'bbbbbbbb', state: 'open', expires_at: '2026-10-08T12:00:00Z', for_human: 'HUM-3' },
      { id: 'aaaaaaaa', state: 'open', expires_at: '2026-10-08T11:00:00Z' },
      { state: 'open' },
    ] })
    assert.deepEqual(rows.map((r) => r.id), ['aaaaaaaa', 'bbbbbbbb', 'cccccccc'])
    assert.equal(rows[1].forHuman, 'HUM-3')
    assert.deepEqual(joinTokenRows(null), [])
  })
  it('never carries a token value', () => {
    const rows = joinTokenRows({ tokens: [{ id: 'aaaaaaaa', token: 'spj1.x.y', state: 'open' }] })
    assert.equal(JSON.stringify(rows).includes('spj1.'), false)
  })
})

describe('joinCountdown', () => {
  const t0 = Date.parse('2026-10-08T10:00:00Z')
  it('reads the expiry from the answer: m:ss under an hour, h:mm:ss above', () => {
    assert.equal(joinCountdown('2026-10-08T10:05:00Z', t0), '5:00')
    assert.equal(joinCountdown('2026-10-08T11:00:00Z', t0), '1:00:00')
    assert.equal(joinCountdown('2026-10-08T10:00:09Z', t0), '0:09')
  })
  it('is empty once passed or unparsable', () => {
    assert.equal(joinCountdown('2026-10-08T10:00:00Z', t0), '')
    assert.equal(joinCountdown('nope', t0), '')
  })
})

describe('joinMintBody / seatedBoxes / joinMemberOptions', () => {
  it('omits empty optional fields', () => {
    assert.deepEqual(joinMintBody({}), {})
    assert.deepEqual(joinMintBody({ label: ' laptop ', boxId: 'Box-A', forHuman: 'hum-3' }), { label: 'laptop', box_id: 'box-a', for_human: 'HUM-3' })
  })
  it('lists each seated box once, never box-wui', () => {
    assert.deepEqual(seatedBoxes([{ box: 'b2' }, { box: 'box-wui' }, { box: 'b1' }, { box: 'b2' }]), ['b1', 'b2'])
  })
  it('offers current members only', () => {
    const now = Date.parse('2026-10-08T10:00:00Z')
    const opts = joinMemberOptions({ members: [
      { human_id: 'HUM-1', display_name: 'Admin' },
      { human_id: 'HUM-2', disabled: true },
      { human_id: 'HUM-3', access_until: '2026-10-01T00:00:00Z' },
      { human_id: 'HUM-4', access_until: '2026-11-01T00:00:00Z' },
    ] }, now)
    assert.deepEqual(opts, [{ id: 'HUM-1', name: 'Admin' }, { id: 'HUM-4', name: 'HUM-4' }])
  })
})

describe('mock hub join tokens', () => {
  it('mint answers the token once; list never carries it; revoke flips the state', () => {
    let now = Date.parse('2026-10-08T10:00:00Z')
    const m = createMockJoinTokens({ now: () => now })
    const r = m.mint({ label: 'laptop' })
    assert.match(r.token, /^spj1\./)
    assert.ok(r.join_line.startsWith('SPOOL_JOIN_TOKEN=' + r.token + ' spool join '))
    assert.equal(JSON.stringify(m.list()).includes('spj1.'), false)
    assert.deepEqual(m.revoke(r.id), { id: r.id, state: 'revoked' })
    assert.equal(m.list().tokens[0].state, 'revoked')
    now += 2 * 60 * 60 * 1000
    assert.equal(m.list().tokens.length, 0)
  })
  it('refuses box-wui like the hub', () => {
    const m = createMockJoinTokens()
    assert.throws(() => m.mint({ box_id: 'box-wui' }), (e) => e.token === 'reserved_box')
    assert.throws(() => m.revokeSeat('box-wui'), (e) => e.token === 'reserved_box')
  })
})

describe('Agents page wiring', () => {
  const page = src('src/pages/tenant-settings/agents.vue')
  it('renders the panel only with agents.join, after me() answered, loaded on demand', () => {
    assert.match(page, /<JoinTokensPanel v-if="mayJoin"/)
    assert.match(page, /accessReady\.value && canJoinAgents\(access\.me\)/)
    assert.match(page, /defineAsyncComponent\(\(\) => import\('~\/components\/JoinTokensPanel\.vue'\)\)/)
  })
  it('the panel keeps no duration literal: the countdown reads expires_at', () => {
    const panel = src('src/components/JoinTokensPanel.vue')
    assert.match(panel, /joinCountdown\(at, now\.value\)/)
    assert.doesNotMatch(panel, /3600|60 \* 60/)
  })
})
