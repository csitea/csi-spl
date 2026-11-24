// SPL-6413 (owner HUM-10, t1 bedfacca msg 3c421dd7): "the drop down of the
// workspaces MUST NOT BE VISIBLE in the login". The sign-in bar names the
// workspace being signed into (the host's, else ?tenant=, else spool-hub) and
// never the session's memberships; the drop box stays for the other pages of
// the sign-in frame (error page, checkout) and the app shell.
//
// Run: node tests/unit/login-workspace.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { isLoginRoute, LOGIN_APEX_LABEL, loginTabName, loginWorkspaceLabel } from '../../src/utils/login-workspace.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const layout = readFileSync(join(WUI, 'src/layouts/login.vue'), 'utf8')
const app = readFileSync(join(WUI, 'src/app.vue'), 'utf8')

describe('isLoginRoute', () => {
  it('is the sign-in page in every locale', () => {
    assert.equal(isLoginRoute('login'), true)
    assert.equal(isLoginRoute('login___en'), true)
    assert.equal(isLoginRoute('login___bg'), true)
  })
  it('is not another page of the sign-in frame', () => {
    for (const n of ['verify-email___en', 'checkout___en', 'checkout-claim___en', 'reset-password', 'login-x___en', '', undefined, null, 42]) {
      assert.equal(isLoginRoute(n), false, String(n))
    }
  })
})

describe('loginWorkspaceLabel', () => {
  it('names the tenant host being signed into', () => {
    assert.equal(loginWorkspaceLabel('acme', '', 't1'), 'acme')
    assert.equal(loginWorkspaceLabel(' Acme ', '', 't1'), 'acme')
  })
  it('falls back to a valid ?tenant= when the host names none', () => {
    assert.equal(loginWorkspaceLabel('', 'globex', 't1'), 'globex')
  })
  it('the host wins over ?tenant=', () => {
    assert.equal(loginWorkspaceLabel('acme', 'globex', 't1'), 'acme')
  })
  it('names spool-hub on the apex, for the apex tenant, and for an invalid value', () => {
    assert.equal(LOGIN_APEX_LABEL, 'spool-hub')
    assert.equal(loginWorkspaceLabel('', '', 't1'), 'spool-hub')
    assert.equal(loginWorkspaceLabel('t1', '', 't1'), 'spool-hub')
    assert.equal(loginWorkspaceLabel('', 't1', 't1'), 'spool-hub')
    assert.equal(loginWorkspaceLabel('', 'not a tenant!', 't1'), 'spool-hub')
    assert.equal(loginWorkspaceLabel(undefined, null, undefined), 'spool-hub')
  })
})

describe('layouts/login.vue: no drop box on the sign-in page', () => {
  it('shows the workspace label on /login and the drop box only off it', () => {
    assert.match(layout, /<span v-if="loginPage && loginWorkspace"[^>]*data-test="login-bar-workspace"/)
    assert.match(layout, /<div v-else-if="tenantShown"[^>]*data-test="login-bar-tenant"/)
    assert.match(layout, /const tenantShown = computed\(\(\) => [^\n]*&& !loginPage\.value\)/)
    assert.match(layout, /const loginPage = computed\(\(\) => isLoginRoute\(route\.name\)\)/)
  })
  it('the label never reads the session (no membership name before sign-in)', () => {
    const line = layout.split('\n').findIndex((l) => l.startsWith('const loginWorkspace = '))
    assert.ok(line > 0)
    const body = layout.split('\n').slice(line, line + 3).join('\n')
    assert.doesNotMatch(body, /session|claims|tenants/)
  })
})

describe('the sign-in tab title (R7 W1)', () => {
  it('names the label, or plain spool-hub on the apex', () => {
    assert.equal(loginTabName('acme'), 'acme.spool-hub')
    assert.equal(loginTabName('spool-hub'), 'spool-hub')
    assert.equal(loginTabName(''), 'spool-hub')
  })
  it('app.vue uses it on /login, never the session there', () => {
    assert.match(app, /const tabName = computed\(\(\) => isLoginRoute\(route\.name\)\n\s+\? loginTabName\(loginWorkspaceLabel\([^\n]*\)\)\n\s+: tenantTabName\(session\.claims/)
  })
})
