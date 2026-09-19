import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  avatarMode, menuButtonLabel, menuButtonLabelKey, methodLabel, methodLabelKey, nextMenuIndex, signInRedirect, userIdentity, userInitials,
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
