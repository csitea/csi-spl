import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const REPO = join(WUI, '..')
const ALLOWED = new Set(['spool-theme', 'spool.verbosity', 'spool.chime', 'spool.read-cursors'])

function walk(dir, acc = []) {
  for (const name of readdirSync(dir, { withFileTypes: true })) {
    if (name.name === 'node_modules' || name.name === '.nuxt' || name.name === '.output') continue
    const p = join(dir, name.name)
    if (name.isDirectory()) walk(p, acc)
    else if (/\.(vue|ts|mjs|js)$/.test(name.name)) acc.push(p)
  }
  return acc
}

describe('verbosity + notify wiring', () => {
  it('VerbositySelector and NotificationCenter do not import mock-data', () => {
    for (const rel of [
      'components/VerbositySelector.vue',
      'components/NotificationCenter.vue',
      'stores/notification.ts',
      'stores/thread.ts',
    ]) {
      const src = readFileSync(join(WUI, rel), 'utf8')
      assert.equal(src.includes('mock-data'), false, rel)
    }
  })

  it('sidebar unread badges read the notification store', () => {
    const src = readFileSync(join(WUI, 'components/ChannelSidebar.vue'), 'utf8')
    assert.equal(src.includes('useNotificationStore'), true)
    assert.equal(src.includes("notes.unread['ch:'"), true)
    assert.equal(src.includes('channel.unread['), false)
  })

  it('live thread pane hosts the verbosity selector', () => {
    const src = readFileSync(join(WUI, 'components/LiveThreadPane.vue'), 'utf8')
    assert.equal(src.includes('VerbositySelector'), true)
    assert.equal(src.includes('applyVerbosity'), true)
  })

  it('channel page no longer pings on send', () => {
    const src = readFileSync(join(WUI, 'pages/channel/[name].vue'), 'utf8')
    assert.equal(src.includes("notes.ping('task sent'"), false)
    assert.equal(src.includes('markRead'), true)
  })

  it('P5 tasks file no longer claims a v:1 metadata block', () => {
    const src = readFileSync(join(REPO, 'csi-spl-doc/specs/005-spool-wui/tasks.md'), 'utf8')
    assert.equal(src.includes('Blocked: metadata not in'), false)
  })

  it('localStorage keys stay on the FR-003 allow-list and never store a token', () => {
    const files = walk(join(WUI, 'components'))
      .concat(walk(join(WUI, 'composables')))
      .concat(walk(join(WUI, 'stores')))
      .concat(walk(join(WUI, 'utils')))
      .concat(walk(join(WUI, 'pages')))
      .concat(walk(join(WUI, 'plugins')))
    const keys = new Set()
    const keyRe = /['"](spool(?:-theme|\.verbosity|\.chime|\.read-cursors))['"]/g
    for (const f of files) {
      const src = readFileSync(f, 'utf8')
      assert.equal(/localStorage\.setItem\([^)]*(token|Authorization|signed)/i.test(src), false, f)
      let m
      while ((m = keyRe.exec(src))) keys.add(m[1])
    }
    for (const k of keys) {
      assert.equal(ALLOWED.has(k), true, k)
    }
    for (const k of ALLOWED) {
      assert.equal(keys.has(k), true, `missing write of ${k}`)
    }
  })
})
