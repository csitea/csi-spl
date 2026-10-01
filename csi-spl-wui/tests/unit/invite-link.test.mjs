// 047 W13 (SPL-1163): an invite whose mail never arrived (a log-only relay,
// a spam folder) can still be handed over: the pending-invite pane copies
// the tenant's sign-in link. The link carries no secret - admission is the
// verified-email match - so it is the same shape the invite mail carries.
//
// Run: node tests/unit/invite-link.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { inviteLink, normalizeDirectory } from '../../src/utils/tenant-users.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('inviteLink', () => {
  it('is <origin>/login?tenant=<id>, the sign-in page the invite mail links', () => {
    assert.equal(inviteLink('https://app.example.com', 't1'), 'https://app.example.com/login?tenant=t1')
    assert.equal(inviteLink('https://app.example.com/', 'acme-2'), 'https://app.example.com/login?tenant=acme-2')
    assert.equal(inviteLink('http://localhost:3000', 'a b'), 'http://localhost:3000/login?tenant=a%20b')
  })
  it('each invite row carries the tenant the member list answered for', () => {
    const d = normalizeDirectory({ tenant_id: 'acme', invites: [{ email: 'p@example.com' }] })
    assert.equal(d.invites[0].tenant, 'acme')
    assert.equal(normalizeDirectory({ invites: [{ email: 'p@example.com' }] }).invites[0].tenant, '')
  })
  it('SPL-1231: carries the invitee address as login_hint (lower-cased); never a non-address', () => {
    assert.equal(inviteLink('https://app.example.com', 't1', 'Office@Acme.BG'), 'https://app.example.com/login?tenant=t1&login_hint=office%40acme.bg')
    assert.equal(inviteLink('https://app.example.com', 't1', 'nope'), 'https://app.example.com/login?tenant=t1')
    assert.equal(inviteLink('https://app.example.com', 't1', ''), 'https://app.example.com/login?tenant=t1')
  })
  it('CONTROL: no tenant or no origin = no link (never a tenant-less sign-in)', () => {
    assert.equal(inviteLink('https://app.example.com', ''), '')
    assert.equal(inviteLink('', 't1'), '')
    assert.equal(inviteLink(undefined, undefined), '')
  })
})

describe('the pending-invite pane', () => {
  const pane = src('src/components/UserEditPane.vue')
  it('offers Copy invite link for a live invite, of the tenant the list came from', () => {
    assert.match(pane, /v-if="linkOf\(invite\)"[\s\S]*?data-test="users-pane-copy-link"/)
    assert.match(pane, /i && !i\.expired && import\.meta\.client \? inviteLink\(window\.location\.origin, i\.tenant, i\.email\)/)
    assert.match(pane, /navigator\.clipboard\.writeText\(link\)/)
  })
  it('only the hub answer "sent" reads as mailed ("logged" does not)', () => {
    // CLE-77780: the create no longer mails (no mail without a click), so only
    // the explicit Send/Resend button (sendMail) reads the 'sent' outcome — one
    // occurrence, not the previous two (create + resend).
    assert.equal((pane.match(/res\?\.mail === 'sent' \? t\('users\.invited'/g) || []).length, 1)
  })
  it('every locale words the button and the hint, with the {email} slot', () => {
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const u = JSON.parse(readFileSync(join(dir, f), 'utf8')).users
      assert.ok(u.copy_link?.trim(), `${f}: users.copy_link`)
      assert.match(u.copy_link_hint || '', /\{email\}/, `${f}: users.copy_link_hint`)
      assert.doesNotMatch(u.copy_link + u.copy_link_hint, /[@<]/, `${f}: '@' or '<' breaks nuxt generate`)
    }
  })
})
