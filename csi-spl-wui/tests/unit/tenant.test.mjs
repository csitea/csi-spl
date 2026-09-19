import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { apiBaseFor, pickTenant, validTenant } from '../../src/utils/tenant.mjs'

describe('tenant host (003 http-v1: tenant = Host; reserved = API host)', () => {
  it('validates tenant labels like msg.ValidTenantID', () => {
    assert.equal(validTenant('t1'), true)
    for (const bad of ['api', 'dev', 'www', 'hub', 'Tee', '-x', '', 'a'.repeat(33)]) assert.equal(validTenant(bad), false, bad)
  })

  it('picks query, then stored, then fallback, skipping invalid ones', () => {
    assert.equal(pickTenant({ query: 'acme', stored: 't2', fallback: 't1' }), 'acme')
    assert.equal(pickTenant({ query: 'api', stored: 't2', fallback: 't1' }), 't2')
    assert.equal(pickTenant({ fallback: 't1' }), 't1')
    assert.equal(pickTenant({}), '')
  })

  it('substitutes {tenant} into the template', () => {
    assert.deepEqual(apiBaseFor('http://{tenant}.localhost:58080/', 't1'), { base: 'http://t1.localhost:58080', error: '' })
    assert.deepEqual(apiBaseFor('https://{tenant}.dev.example.com', 'acme'), { base: 'https://acme.dev.example.com', error: '' })
    assert.equal(apiBaseFor('https://{tenant}.dev.example.com', '').error, 'no_tenant')
    assert.equal(apiBaseFor('https://{tenant}.dev.example.com', 'api').error, 'no_tenant')
  })

  it('refuses the API host for tenant reads', () => {
    assert.equal(apiBaseFor('https://api.example.com', '').error, 'api_host')
    assert.equal(apiBaseFor('https://dev.api.example.com', '').error, 'api_host')
    assert.equal(apiBaseFor('https://dev.example.com', '').error, 'api_host')
  })

  it('keeps a fixed tenant origin and single-label lde hosts', () => {
    assert.deepEqual(apiBaseFor('http://t1.localhost:58080', ''), { base: 'http://t1.localhost:58080', error: '' })
    assert.deepEqual(apiBaseFor('http://localhost:58080', ''), { base: 'http://localhost:58080', error: '' })
    assert.equal(apiBaseFor('', 't1').error, 'no_base')
  })
})
