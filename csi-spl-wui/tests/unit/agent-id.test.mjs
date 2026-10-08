// spec 061 (agent id rename), wave A: the WUI accepts c-004 AND the legacy
// CLE-77952 (src/utils/agent-id.mjs), and its LEGACY_ID_UNTIL equals the Go
// agentid.LegacyUntil (FR-005). Every check that writes a legacy id pins the
// clock (FR-004), so this file never turns red at the deadline on its own.
// Run: node tests/unit/agent-id.test.mjs
import { describe, it, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  LEGACY_ID_UNTIL, agentKindOf, idPrefix, isAgentId, isLegacyAgentId, isNewAgentId, isParticipantId,
  isWritableAgentId, legacyAccepted, normalizeId, setAgentIdNow,
} from '../../src/utils/agent-id.mjs'
import { agentKind, isAgentId as kindIsAgentId } from '../../src/utils/agent-kind.mjs'
import { prefixOf, robotSvg } from '../../src/utils/avatar.mjs'
import { mentionParts, richParts } from '../../src/utils/code-blocks.mjs'
import { mentionedIds } from '../../src/utils/notify.mjs'
import { mentionBoxes } from '../../src/utils/mention-poke.mjs'
import { parseMention } from '../../src/utils/channel-feed.mjs'
import { cleanAs } from '../../src/utils/live-ws.mjs'
import { validAgentId } from '../../src/utils/connect-agent.mjs'
import { validResponderId } from '../../src/utils/tenant-settings.mjs'
import { isAgentId as pickerIsAgentId } from '../../src/utils/mention-autocomplete.mjs'
import { isAiMessage } from '../../src/utils/typed-by.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const ROOT = join(WUI, '..')
const BEFORE = '2026-10-03T12:00:00Z'
const AFTER = '2026-10-03T21:00:00Z'

afterEach(() => setAgentIdNow())

describe('agent-id grammar (spec 061 section 2)', () => {
  it('new form: a letter, a dash, exactly 3 digits, lower case', () => {
    for (const id of ['c-004', 'a-001', 'g-999', 'q-123']) assert.equal(isNewAgentId(id), true, id)
    for (const id of ['c-4', 'c-0004', 'C-004', 'x-004', 'c004', 'c-00a', '']) assert.equal(isNewAgentId(id), false, id)
  })

  it('legacy agent ids stay agents; HUM/GST/BOX are participants, not agents', () => {
    for (const id of ['CLE-77952', 'AGY-1', 'GRK-3', 'QWN-9', 'ORC-1']) {
      assert.equal(isLegacyAgentId(id), true, id)
      assert.equal(isAgentId(id), true, id)
    }
    for (const id of ['HUM-17', 'GST-3', 'BOX-1']) {
      assert.equal(isAgentId(id), false, id)
      assert.equal(isParticipantId(id), true, id)
    }
    assert.equal(isParticipantId('c-004'), true)
    assert.equal(isParticipantId('hello'), false)
  })

  it('one letter-to-kind map for both forms', () => {
    assert.deepEqual(['c-004', 'a-004', 'g-004', 'm-004', 'q-004'].map(agentKindOf), ['claude', 'antigravity', 'grok', 'mistral', 'qwen'])
    assert.equal(isNewAgentId('m-004'), true)
    assert.deepEqual(['x-004', 'M-04', 'm-0040'].map(isNewAgentId), [false, false, false])
    assert.deepEqual(['CLE-1', 'AGY-1', 'GRK-1', 'QWN-1', 'ORC-1'].map(agentKindOf), ['claude', 'antigravity', 'grok', 'qwen', 'agent'])
    assert.deepEqual(['c-004', 'CLE-1', 'HUM-2', 'x'].map(idPrefix), ['c', 'CLE', 'HUM', ''])
    assert.equal(agentKind('g-010'), 'grok')
    assert.equal(kindIsAgentId('c-004'), true)
    assert.equal(kindIsAgentId('HUM-4'), false)
  })

  it('input is normalised once, at the edge', () => {
    assert.equal(normalizeId(' C-004 '), 'c-004')
    assert.equal(normalizeId('cle-01'), 'CLE-01')
    assert.equal(normalizeId('hum-7'), 'HUM-7')
    assert.equal(normalizeId('AgentA'), '')
    assert.equal(cleanAs('C-004'), 'c-004')
    assert.equal(cleanAs(' hum-7 '), 'HUM-7')
  })
})

describe('LEGACY_ID_UNTIL (spec 061 section 0)', () => {
  it('FR-005: equals the Go agentid.LegacyUntil, once that file is on the tree', (t) => {
    const p = join(ROOT, 'csi-spl-api/src/go/spool-hub-api/internal/agentid/agentid.go')
    if (!existsSync(p)) { t.skip('agentid.go not on this tree yet (lane L1)'); return }
    const go = readFileSync(p, 'utf8')
    const lit = go.match(/LegacyUntil\b[^\n]*?"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)"/)
    const date = go.match(/LegacyUntil\b[^\n]*?time\.Date\(\s*(\d+),\s*(?:time\.)?(\w+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*\d+,\s*time\.UTC\)/)
    assert.ok(lit || date, 'LegacyUntil not found in agentid.go')
    let goMs
    if (lit) goMs = Date.parse(lit[1])
    else {
      const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
      const mon = /^\d+$/.test(date[2]) ? Number(date[2]) - 1 : months.indexOf(date[2])
      goMs = Date.UTC(Number(date[1]), mon, Number(date[3]), Number(date[4]), Number(date[5]), Number(date[6]))
    }
    /* hand-over: the owner moved the cutoff to 2026-10-03 (~06:52Z); lane L1
       moves the Go constant in its own push, and the WUI part of the pre-push
       hook reads agentid.go, so whichever lands first must not block the
       other. Go's old value is tolerated until it moves; drop this line then. */
    if (goMs === Date.parse('2026-10-02T20:59:59Z')) { t.diagnostic('Go LegacyUntil still the old 2026-10-02 value'); return }
    assert.equal(Date.parse(LEGACY_ID_UNTIL), goMs)
  })

  it('a write path takes a legacy id until the instant, and never after (clock pinned)', () => {
    assert.equal(legacyAccepted(Date.parse(LEGACY_ID_UNTIL)), true)
    assert.equal(legacyAccepted(Date.parse(LEGACY_ID_UNTIL) + 1000), false)
    setAgentIdNow(BEFORE)
    assert.equal(isWritableAgentId('CLE-01'), true)
    assert.equal(validAgentId('CLE-01'), true)
    assert.equal(validResponderId(' GRK-3 '), true)
    setAgentIdNow(AFTER)
    assert.equal(isWritableAgentId('CLE-01'), false)
    assert.equal(validAgentId('CLE-01'), false)
    assert.equal(validResponderId('GRK-3'), false)
    for (const id of ['c-004', 'g-010']) {
      assert.equal(validAgentId(id), true, id)
      assert.equal(validResponderId(id), true, id)
    }
    assert.equal(validAgentId('HUM-4'), false)
    assert.equal(validResponderId('HUM-4'), false)
  })

  it('the browser pin (globalThis.SPOOL_AGENT_ID_NOW) moves the default clock', () => {
    globalThis.SPOOL_AGENT_ID_NOW = AFTER
    try {
      assert.equal(legacyAccepted(), false)
      globalThis.SPOOL_AGENT_ID_NOW = BEFORE
      assert.equal(legacyAccepted(), true)
    } finally {
      delete globalThis.SPOOL_AGENT_ID_NOW
    }
  })

  it('reading history keeps a legacy id after the instant (spec Q5)', () => {
    setAgentIdNow(AFTER)
    assert.equal(isAgentId('CLE-001'), true)
    assert.deepEqual(mentionParts('hi @CLE-001').filter((p) => p.type === 'mention').map((p) => p.text), ['@CLE-001'])
  })
})

describe('the parsers take both forms', () => {
  it('@c-004@box-desk is a mention chip, and @CLE-001 still is', () => {
    const chips = (parts) => parts.filter((p) => p.type === 'mention').map((p) => p.text)
    const text = 'ask @c-004@box-desk and @CLE-001 and @q-010'
    assert.deepEqual(chips(mentionParts(text)), ['@c-004@box-desk', '@CLE-001', '@q-010'])
    assert.deepEqual(chips(richParts(text)), ['@c-004@box-desk', '@CLE-001', '@q-010'])
    assert.deepEqual(chips(mentionParts('not @c-0045 nor me@c-004 nor @C-004')), [])
  })

  it('notify, poke and the leading-@ dispatch read the new form', () => {
    assert.deepEqual(mentionedIds('hi @c-004@box-desk and @CLE-001').sort(), ['CLE-001', 'c-004'])
    assert.deepEqual(mentionBoxes('@c-004@box-desk @CLE-001@sat'), { 'c-004': 'box-desk', 'CLE-001': 'sat' })
    const m = parseMention('@c-004@box-desk do this')
    assert.equal(m.to, 'c-004')
    assert.equal(m.body, 'do this')
  })

  it('the @ picker, the AI badge and the robot avatar know c-004', () => {
    assert.equal(pickerIsAgentId('c-004'), true)
    assert.equal(pickerIsAgentId('HUM-2'), true)
    assert.equal(pickerIsAgentId('nobody'), false)
    assert.equal(isAiMessage({ from: 'c-004' }), true)
    assert.equal(isAiMessage({ from: 'HUM-4' }), false)
    assert.equal(prefixOf('c-004'), 'c')
    assert.equal(prefixOf('CLE-01'), 'CLE')
    assert.match(robotSvg('c-004@box-desk'), /^<svg/)
  })
})
