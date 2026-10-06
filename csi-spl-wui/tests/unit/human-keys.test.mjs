// specs/023 T021 — browser key generation and encodings, cross-checked
// against node:crypto's own Ed25519 (the same primitive `spool keygen` uses
// in Go). Run: node tests/unit/human-keys.test.mjs
import assert from 'node:assert/strict'
import { createPublicKey, createPrivateKey, sign, verify, webcrypto } from 'node:crypto'
import {
  classifyPublicKeyInput,
  createKeysClient,
  ed25519Supported,
  generateHumanKeyPair,
  humanKeyFileNames,
  keysErrorKey,
  pinFormBytes,
  sshFingerprint,
  sshPublicLine,
} from '../../src/utils/human-keys.mjs'

const subtle = webcrypto.subtle
let n = 0
const ok = (name) => { n++; console.log(`  OK   ${name}`) }

console.log('human-keys')

assert.equal(await ed25519Supported(subtle), true)
assert.equal(await ed25519Supported(null), false)
ok('ed25519Supported')

// The spool private form is seed||pub (64 bytes): rebuild a node key from the
// seed and prove it signs for the exported public key.
const kp = await generateHumanKeyPair(subtle)
const priv = Buffer.from(kp.privateKey, 'base64')
const pub = Buffer.from(kp.publicKey, 'base64')
assert.equal(priv.length, 64)
assert.equal(pub.length, 32)
assert.deepEqual(priv.subarray(32), pub, 'private = seed || pub')
const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), priv.subarray(0, 32)])
const nodePriv = createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' })
const spki = Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), pub])
const nodePub = createPublicKey({ key: spki, format: 'der', type: 'spki' })
const sig = sign(null, Buffer.from('spool'), nodePriv)
assert.ok(verify(null, Buffer.from('spool'), nodePub, sig), 'seed from the pkcs8 export signs for the raw public key')
ok('generateHumanKeyPair: spool formats, seed||pub signs')

// OpenSSH line + fingerprint: pinned to ssh-keygen output (Go's pubkey_test.go
// pins the same vectors).
const zero = new Uint8Array(32)
assert.equal(sshPublicLine(zero), 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')
assert.equal(await sshFingerprint(zero, subtle), 'SHA256:kmYcvdi2GkPeWxB6XLjrZB8JHsy2Hm8luHMFp9GMvqk')
const real = pinFormBytes(Buffer.from('AAAAC3NzaC1lZDI1NTE5AAAAIAuxpwgDCEfyJLzw0RDRZToUpFjnh8ce/+CaVQ7bxars', 'base64').subarray(19).toString('base64'))
assert.equal(await sshFingerprint(real, subtle), 'SHA256:b50O9136QC+qHvRlKdf6A0cK7az1IOsUpvB5Vk1WcQ0')
assert.equal(sshPublicLine(zero, 'spool:HUM-1').endsWith(' spool:HUM-1'), true)
ok('sshPublicLine + sshFingerprint match ssh-keygen')

// CONTROLS: the early classifier refuses private material and junk.
assert.equal(classifyPublicKeyInput(kp.publicKey), 'ok')
assert.equal(classifyPublicKeyInput(sshPublicLine(kp.pub, 'x')), 'ok')
assert.equal(classifyPublicKeyInput(kp.privateKey), 'private')
assert.equal(classifyPublicKeyInput('-----BEGIN OPENSSH ' + 'PRIVATE KEY-----\nabc\n-----END OPENSSH ' + 'PRIVATE KEY-----'), 'private')
assert.equal(classifyPublicKeyInput(''), 'bad')
assert.equal(classifyPublicKeyInput('hello world'), 'bad')
assert.equal(classifyPublicKeyInput('ssh-ed25519 AAAA'), 'bad')
ok('classifyPublicKeyInput')

assert.deepEqual(humanKeyFileNames('HUM-12'), { private: 'HUM-12.key', public: 'HUM-12.pub', openssh: 'HUM-12.openssh.pub' })
assert.equal(humanKeyFileNames('../x').private, 'spool-human.key')
ok('humanKeyFileNames')

// The client sends ONLY the public key, with credentials, to <base>/api/v1/auth/keys.
const calls = []
const fetchFn = async (url, opts) => {
  calls.push({ url, opts })
  if (opts.method === 'POST' && url.endsWith('/keys')) {
    return { ok: false, status: 409, headers: { get: () => null }, json: async () => ({ error: 'duplicate_key' }) }
  }
  return { ok: true, status: 200, headers: { get: () => null }, json: async () => ({ active: null, keys: [] }) }
}
const c = createKeysClient({ fetchFn, base: 'https://api.example.com' })
const l = await c.list()
assert.equal(l.ok, true)
assert.equal(calls[0].url, 'https://api.example.com/api/v1/auth/keys')
assert.equal(calls[0].opts.credentials, 'include')
assert.ok(calls[0].opts.signal instanceof AbortSignal, 'a hung connection times out (refactor r4-03)')
const a = await c.add({ publicKey: kp.publicKey, source: 'generated' })
assert.equal(a.error, 'duplicate_key')
const sent = JSON.parse(calls[1].opts.body)
assert.deepEqual(Object.keys(sent).sort(), ['label', 'public_key', 'source'])
assert.ok(!calls[1].opts.body.includes(kp.privateKey), 'the private key never leaves the page')
await c.revoke(7)
assert.equal(calls[2].url, 'https://api.example.com/api/v1/auth/keys/7/revoke')
const down = await createKeysClient({ fetchFn: async () => { throw new Error('x') } }).list()
assert.equal(down.error, 'network')
ok('createKeysClient')

assert.equal(keysErrorKey('duplicate_key'), 'settings.keys.error.duplicate_key')
assert.equal(keysErrorKey('weird'), 'settings.keys.error.generic')
ok('keysErrorKey')

console.log(`\n${n} passed`)
