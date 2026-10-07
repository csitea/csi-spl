import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import {
  avatarMode, CHANGE_PASSWORD_PATH, changePasswordOffered, menuButtonLabel, ownAvatarUrl, menuButtonLabelKey, methodLabel, methodLabelKey, nextMenuIndex, signInRedirect, userIdentity, userInitials,
} from '../../src/utils/user-menu.mjs'

describe('user menu identity (CLE-3402: top-right avatar from auth-v1 §4 session claims)', () => {
  it('reads name, email, member id, method and tenant from the claims', () => {
    const u = userIdentity({ p: 'google', email: 'a@example.com', name: 'FirstName LastName', hum: 'HUM-3', t: 't1' })
    assert.deepEqual(u, {
      hum: 'HUM-3', name: 'FirstName LastName', email: 'a@example.com', method: 'google', tenant: 't1',
      primary: 'FirstName LastName', secondary: 'a@example.com',
    })
  })

  it('falls back name -> email -> member id, and never repeats the first line', () => {
    assert.equal(userIdentity({ email: 'a@example.com', hum: 'HUM-3' }).primary, 'a@example.com')
    assert.equal(userIdentity({ email: 'a@example.com', hum: 'HUM-3' }).secondary, 'HUM-3')
    assert.equal(userIdentity({ hum: 'HUM-3' }).primary, 'HUM-3')
    assert.equal(userIdentity({ hum: 'HUM-3' }).secondary, '')
  })

  it('drops a malformed or guest member id and non-string claims', () => {
    assert.equal(userIdentity({ hum: 'GST-1' }).hum, '')
    assert.equal(userIdentity({ hum: 'HUM-x' }).hum, '')
    assert.equal(userIdentity({ name: 42, email: null }).primary, '')
    assert.equal(userIdentity(null).primary, '')
  })

  it('initials: first+last name, else two letters of the name, else of the email local part', () => {
    assert.equal(userInitials({ name: 'first middle last' }), 'FL')
    assert.equal(userInitials({ name: 'solo' }), 'SO')
    assert.equal(userInitials({ email: 'xy.z@example.com' }), 'XY')
    assert.equal(userInitials({ email: 'q' }), 'Q')
    assert.equal(userInitials({}), '')
  })

  it('avatar: a member draws the identicon/IdP picture, else initials, else the silhouette', () => {
    assert.equal(avatarMode({ hum: 'HUM-7', email: 'a@example.com' }), 'member')
    assert.equal(avatarMode({ email: 'a@example.com' }), 'initials')
    assert.equal(avatarMode({}), 'silhouette')
    assert.equal(avatarMode(null), 'silhouette')
  })

  it('names the menu button for screen readers', () => {
    assert.equal(menuButtonLabel({ email: 'a@example.com' }), 'Account menu for a@example.com')
    assert.equal(menuButtonLabel({}), 'Account menu')
  })

  it('says the sign-in method in words', () => {
    assert.equal(methodLabel('password'), 'Email and password')
    assert.equal(methodLabel('Google'), 'Google')
    assert.equal(methodLabel('github'), 'Github')
    assert.equal(methodLabel(''), 'Unknown')
  })

  it('spec 021: the catalogue keys render the same English', () => {
    const EN = {
      'user_menu.method_unknown': 'Unknown',
      'user_menu.method_password': 'Email and password',
      'user_menu.method_named': '{name}',
      'user_menu.account_menu': 'Account menu',
      'user_menu.account_menu_for': 'Account menu for {who}',
    }
    const render = ({ key, params }) => EN[key].replace(/\{(\w+)\}/g, (_, p) => String(params[p]))
    for (const p of ['password', 'Google', 'github', '', 'facebook', ' PASSWORD ']) {
      assert.equal(render(methodLabelKey(p)), methodLabel(p), JSON.stringify(p))
    }
    for (const c of [{ email: 'a@example.com' }, {}, null, { name: 'FirstName LastName' }]) {
      assert.equal(render(menuButtonLabelKey(c)), menuButtonLabel(c), JSON.stringify(c))
    }
  })
})

describe('user menu keyboard (WAI-ARIA menu button)', () => {
  it('arrows wrap, Home/End jump, Escape/Tab close', () => {
    assert.equal(nextMenuIndex(-1, 'ArrowDown', 3), 0)
    assert.equal(nextMenuIndex(2, 'ArrowDown', 3), 0)
    assert.equal(nextMenuIndex(-1, 'ArrowUp', 3), 2)
    assert.equal(nextMenuIndex(0, 'ArrowUp', 3), 2)
    assert.equal(nextMenuIndex(1, 'Home', 3), 0)
    assert.equal(nextMenuIndex(0, 'End', 3), 2)
    assert.equal(nextMenuIndex(1, 'Escape', 3), -1)
    assert.equal(nextMenuIndex(1, 'Tab', 3), -1)
    assert.equal(nextMenuIndex(1, 'a', 3), 1)
    assert.equal(nextMenuIndex(0, 'ArrowDown', 0), -1)
  })
})

describe('sign-in entry redirect', () => {
  it('comes back to where the person was, never to /login or off-origin', () => {
    assert.equal(signInRedirect('/channel/abc?x=1'), '/channel/abc?x=1')
    assert.equal(signInRedirect('/login?redirect=/x'), '/')
    assert.equal(signInRedirect('/login'), '/')
    assert.equal(signInRedirect('//evil.example.com'), '/')
    assert.equal(signInRedirect('https://evil.example.com'), '/')
    assert.equal(signInRedirect(''), '/')
    assert.equal(signInRedirect('/loginx'), '/loginx')
    // spec 021: the locale-prefixed sign-in page is /login too
    assert.equal(signInRedirect('/fi/login'), '/')
    assert.equal(signInRedirect('/he/login?redirect=/x'), '/')
    assert.equal(signInRedirect('/fi/loginx'), '/fi/loginx')
    assert.equal(signInRedirect('/fi/settings'), '/fi/settings')
  })
})

describe('CLE-3406: the corner shows the person\'s own IdP picture', () => {
  it('asks the auth base for it with the session alone - a member and a not-yet-member alike', () => {
    const member = { p: 'google', email: 'a@example.com', hum: 'HUM-3', iat: 1758300000 }
    const invited = { p: 'google', email: 'a@example.com', iat: 1758300001 }
    assert.equal(ownAvatarUrl('https://api.example.com/', member), 'https://api.example.com/api/v1/auth/avatar?at=1758300000')
    assert.equal(ownAvatarUrl('https://api.example.com', invited), 'https://api.example.com/api/v1/auth/avatar?at=1758300001')
    assert.equal(ownAvatarUrl('', { email: 'a@example.com' }), '/api/v1/auth/avatar')
  })

  it('a new sign-in is a new URL, so a picture changed at the IdP is not the cached one', () => {
    const a = ownAvatarUrl('https://h', { iat: 1 })
    const b = ownAvatarUrl('https://h', { iat: 2 })
    assert.notEqual(a, b)
  })

  it('CONTROL: signed out -> no request (the sign-in entry shows)', () => {
    assert.equal(ownAvatarUrl('https://h', null), '')
    assert.equal(ownAvatarUrl('https://h', undefined), '')
  })
})

describe('user menu panel is RTL-safe (spec 021 FR-004: logical properties)', () => {
  const css = readFileSync(new URL('../../src/components/UserMenu.vue', import.meta.url), 'utf8').split('<style')[1] || ''
  it('anchors the panel to the inline end and aligns items to the start', () => {
    assert.match(css, /\.user-menu__panel \{[^}]*inset-inline-end: 0;/)
    assert.match(css, /\.user-menu__item \{[^}]*text-align: start;/)
  })
  it('CONTROL: no physical left/right offset or left/right text-align in the menu styles', () => {
    assert.doesNotMatch(css, /(^|[\s;{])(left|right): /m)
    assert.doesNotMatch(css, /text-align: (left|right)/)
  })
})

describe('a rotation never shows the CLOSED menu (v-show owns display)', () => {
  const src = readFileSync(new URL('../../src/components/UserMenu.vue', import.meta.url), 'utf8').split('<style')[0]
  it('the only bare style wipe is clearPopover, and it puts display back', () => {
    assert.equal(src.split("removeAttribute('style')").length - 1, 1)
    const fn = src.match(/function clearPopover\([^)]*\) \{([\s\S]*?)\n\}/)
    assert.ok(fn, 'clearPopover exists')
    assert.match(fn[1], /const display = panel\.style\.display[\s\S]*removeAttribute\('style'\)[\s\S]*panel\.style\.display = display/)
  })
  it('the narrow watch and the phone path both go through it', () => {
    assert.match(src, /watch\(narrow, \(\) => \{\s*clearPopover\(/)
    assert.match(src, /if \(phone\(\)\) \{ clearPopover\(panel\); return \}/)
  })
})

describe('t1 ea0af569 (B): Change password in the account menu and on the own profile', () => {
  it('is offered to a password session only', () => {
    assert.equal(changePasswordOffered({ p: 'password', hum: 'HUM-1' }), true)
    assert.equal(changePasswordOffered({ p: 'google', hum: 'HUM-1' }), false)
    assert.equal(changePasswordOffered({ p: 'github', hum: 'HUM-1' }), false)
    assert.equal(changePasswordOffered({ hum: 'HUM-1' }), false)
    assert.equal(changePasswordOffered(null), false)
  })
  it('is never offered while acting as someone else', () => {
    assert.equal(changePasswordOffered({ p: 'password' }, { targetName: 'Dev One' }), false)
  })
  it('opens the existing Settings section, no new form', () => {
    assert.equal(CHANGE_PASSWORD_PATH, '/settings/security')
    const nav = readFileSync(new URL('../../src/utils/settings-nav.mjs', import.meta.url), 'utf8')
    assert.match(nav, /id: 'security'/)
  })
  it('the label is in every locale', () => {
    const dir = new URL('../../i18n/locales/', import.meta.url)
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
      const v = JSON.parse(readFileSync(new URL(f, dir), 'utf8')).user_menu?.change_password
      assert.ok(typeof v === 'string' && v.trim(), f)
    }
  })
})
