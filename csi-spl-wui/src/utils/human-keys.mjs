/**
 * Settings → Keys (specs/023 §3.1-3.2, contracts/keys-v1.md).
 *
 * The default Ed25519 pair is generated HERE, in the browser (WebCrypto), and
 * only the public key is sent to the hub; the private key lives in page
 * memory until the person downloads it. Encodings match the spool CLI:
 *   private  base64(64-byte seed‖pub) + '\n'   (spool keygen / root-keygen)
 *   public   base64(32 bytes) + '\n'            (a pin value, spool pin --pubkey)
 *   openssh  'ssh-ed25519 <b64 blob> spool:<HUM-n>'
 * Pure helpers take their crypto / fetch as arguments so node tests drive
 * them with node:crypto's webcrypto.
 */

import { AUTH_PREFIX, authOrigin } from './auth-client.mjs'

const SSH_ED25519 = 'ssh-ed25519'

function b64(bytes) {
  let s = ''
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s)
}

function unb64(str) {
  const bin = atob(str)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

function u32(n) {
  return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]
}

/** The OpenSSH wire blob: string("ssh-ed25519") || string(pub). */
export function sshKeyBlob(pub) {
  const name = new TextEncoder().encode(SSH_ED25519)
  return new Uint8Array([...u32(name.length), ...name, ...u32(pub.length), ...pub])
}

/** The authorized_keys line for a 32-byte public key. */
export function sshPublicLine(pub, comment = '') {
  const line = `${SSH_ED25519} ${b64(sshKeyBlob(pub))}`
  return comment ? `${line} ${comment}` : line
}

/** OpenSSH's fingerprint ("SHA256:" + unpadded base64), as `ssh-keygen -lf`. */
export async function sshFingerprint(pub, subtle = globalThis.crypto?.subtle) {
  const sum = new Uint8Array(await subtle.digest('SHA-256', sshKeyBlob(pub)))
  return 'SHA256:' + b64(sum).replace(/=+$/, '')
}

/** True when this browser's WebCrypto can make Ed25519 keys. */
export async function ed25519Supported(subtle = globalThis.crypto?.subtle) {
  if (!subtle) return false
  try {
    await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])
    return true
  } catch {
    return false
  }
}

/**
 * A fresh pair in the spool formats: { publicKey: '<44-char b64>',
 * privateKey: '<88-char b64>', pub: Uint8Array(32) }. The seed is the last
 * 32 bytes of the PKCS#8 export (RFC 8410: a fixed 16-byte prefix).
 */
export async function generateHumanKeyPair(subtle = globalThis.crypto?.subtle) {
  const kp = await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])
  const pub = new Uint8Array(await subtle.exportKey('raw', kp.publicKey))
  const pkcs8 = new Uint8Array(await subtle.exportKey('pkcs8', kp.privateKey))
  const seed = pkcs8.slice(pkcs8.length - 32)
  const priv = new Uint8Array(64)
  priv.set(seed, 0)
  priv.set(pub, 32)
  return { publicKey: b64(pub), privateKey: b64(priv), pub }
}

/**
 * Client-side read of an uploaded public key (the hub decides; this only
 * gives an early, specific message): 'ok' | 'private' | 'bad'.
 */
export function classifyPublicKeyInput(text) {
  const s = String(text || '').trim()
  if (!s) return 'bad'
  if (/PRIVATE KEY/i.test(s)) return 'private'
  const f = s.split(/\s+/)
  let raw
  try {
    raw = f[0] === SSH_ED25519 && f.length >= 2 ? unb64(f[1]) : unb64(s)
  } catch {
    return 'bad'
  }
  if (f[0] === SSH_ED25519) return raw.length === 51 ? 'ok' : 'bad'
  if (raw.length === 32) return 'ok'
  if (raw.length === 64 || raw.length === 48) return 'private'
  return 'bad'
}

/** Download file names: HUM-12.key, HUM-12.pub, HUM-12.openssh.pub. */
export function humanKeyFileNames(hum) {
  const base = /^HUM-\d+$/.test(String(hum || '')) ? String(hum) : 'spool-human'
  return { private: `${base}.key`, public: `${base}.pub`, openssh: `${base}.openssh.pub` }
}

/** The public key bytes of a pin-form value. */
export function pinFormBytes(pinForm) {
  return unb64(String(pinForm || '').trim())
}

/**
 * keys-v1 client. Every call resolves (never throws) to
 * { ok, status, data, error, retryAfter }.
 */
export function createKeysClient({ fetchFn = globalThis.fetch, base = '' } = {}) {
  const root = `${authOrigin(base)}${AUTH_PREFIX}/keys`
  async function call(path, opts = {}) {
    let res
    try {
      res = await fetchFn(root + path, {
        credentials: 'include',
        cache: 'no-store',
        ...opts,
        headers: { accept: 'application/json', ...(opts.body ? { 'content-type': 'application/json' } : {}) },
      })
    } catch {
      return { ok: false, status: 0, data: null, error: 'network', retryAfter: 0 }
    }
    let data = null
    try { data = await res.json() } catch { data = null }
    if (res.ok) return { ok: true, status: res.status, data, error: '', retryAfter: 0 }
    const ra = res.headers && typeof res.headers.get === 'function' ? Number(res.headers.get('retry-after')) : 0
    return {
      ok: false,
      status: res.status,
      data,
      error: String((data && data.error) || (res.status === 429 ? 'rate_limited' : 'unavailable')),
      retryAfter: Number.isFinite(ra) && ra > 0 ? ra : 0,
    }
  }
  return {
    list: () => call(''),
    /** Only the public key ever leaves the page. */
    add: ({ publicKey = '', source = 'uploaded', label = '' } = {}) =>
      call('', { method: 'POST', body: JSON.stringify({ public_key: String(publicKey || ''), source, label: String(label || '') }) }),
    revoke: (id) => call(`/${encodeURIComponent(String(id))}/revoke`, { method: 'POST', body: '{}' }),
  }
}

/** i18n key for a keys-v1 error token. */
export function keysErrorKey(error) {
  const known = ['bad_public_key', 'private_key_refused', 'duplicate_key', 'rate_limited', 'unauthenticated', 'network']
  return `settings.keys.error.${known.includes(error) ? error : 'generic'}`
}
